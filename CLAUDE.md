# CLAUDE.md

Plain-bash provisioning scripts that turn a **fresh** Debian 12/13 server into a Laravel host
with zero-downtime deployments (nginx + php-fpm + MariaDB + Redis + Node), plus the local
tools used to deploy to it. Public repo: `github.com/rvwoens/debian-laravel-stack`.
The user runs it as root on a new VPS (often Linode) via the tarball one-liner in README.md.

Design rules the user cares about:
- **Fresh installs only.** No upgrade path, no idempotency guarantees. Parts write config
  files from scratch and may append to files (`/etc/sudoers`, `/etc/hosts`, `.bashrc`) again
  if re-run. Don't add "upgrade an existing server" logic unless asked.
- **Keep it simple bash.** No Docker, Ansible or frameworks. Readable, tweakable scripts.
- Explanatory comments are welcome: existing parts document *why* (e.g. why CrowdSec is
  disabled, why sshd drop-in is `00-`). Keep that style when changing behaviour.

## Layout

| Path | What it is |
|---|---|
| `setup_full` | Root entry point. Sources parts 01-12 in order, then offers a forced reboot. |
| `setup_clean` | Minimal variant: parts 01-06 only (user, hostname, packages, root, security, globals). |
| `parts/00_settings` | Shared settings sourced by every part: `PHPVER` (8.3), `NODEVER` (`lts`), `logline`, colors, `OS_ID`/`OS_VERSION`, `INSTALLPWD`, apt non-interactive env + `APT_CONF_OPTS`, `valid_reboottime`/`ask_reboottime` (HH:MM check + prompt, used by 02 and 05). |
| `parts/NN_*` | One install step each (01 user, 02 hostname + all up-front questions, 03 apt/Sury/gh/glab, 04 root pw, 05 sshd/ufw/fail2ban/unattended-upgrades, 06 tz/locale/python/cowsay, 07 php+composer, 08 node, 09 mariadb, 10 nginx+certbot, 11 /var/www + demo laravel, 12 redis). |
| `parts/userbin/` | Copied to `~/bin` of the created user by part 01: `addzhost`, `artisan`, `clear-laravel`, `logtail`, `release-cleanup`, `dbRemote2local`, `github-auth`, `gitlab-auth`. |
| `parts/userbin/lib/` | Libraries **sourced** by `addzhost`: `addzhost-repo.sh` (git access check, deploy-key auto-add via gh/glab), `addzhost-ssl.sh` (certbot). |
| `parts/usercron/crondef` | User crontab file installed to `~/crontab/`; `addzhost` appends `schedule:run` lines to it. |
| `parts/assets/homepage/` | Default landing page copied to `/var/www/html`. |
| `local_support/` | Tools that run on the **dev machine**: `pusher`, `newversion`, `pusher.conf.example`. |
| `pusher_this` | Release script for *this* repo (see Releasing). |
| `VERSION` | Written by `pusher_this`. Don't edit by hand. |

The sibling directory `../centos-laravel-stack` is the older CentOS version this was ported
from; the commented-out `yum`/`remi` lines in some parts are left over from it.

## How the parts work together

- `setup_full` **sources** each part (`. ./parts/NN_x`), so all variables live in one shell.
  `username` from 01 is used by every later part.
- Each part starts with `. ${BASH_SOURCE%/*}/00_settings` so it can also be run on its own:
  `bash ./parts/NN_x` (as root, from the repo root).
- **All optional questions are asked up front in `02_set_hostname`** (rootpas, timezone,
  doautoupdate + reboottime, docowsay, donode/doyarn/dopnpm, domysql + mysqlpwd, doredis,
  dolaravelwebsite), so the rest runs unattended. Each consuming part has a fallback prompt guarded by
  `[ -z "${var+set}" ]`. That means "never asked", so an empty answer (= the default) is not
  asked again. When adding a new optional step, follow the same pattern: ask in 02, guard
  in the part.
- The header comment in 02 says answers can be pre-set from the environment for `setup_full`,
  but 02 asks every question without checking first, so a pre-set value gets overwritten. Pre-set
  values only work when running a single part, e.g.
  `doautoupdate=y reboottime=04:00 bash ./parts/05_security`.
- Yes/no checks: `[Y/n]` defaults are tested with `[ ! "$x" = "n" ]` (only lowercase `n`
  says no); `[y/N]` defaults test `y`/`Y` explicitly. Not fully consistent across parts.

## Conventions when editing parts

- **Tabs, not spaces.** Many heredocs use `<<-EOF`, which only strips leading *tabs*.
  Converting indentation to spaces breaks the terminators and the generated file contents.
- Progress lines: `logline "NN.MM description"`, starting with `NN.00 ... START` and ending
  with `NN.99 ... END`, where NN matches the part number.
- apt: always `-y`. Use `"${APT_CONF_OPTS[@]}"` for anything that might hit a config-file
  conflict (upgrades, services with `/etc` configs). `DEBIAN_FRONTEND=noninteractive` and
  `NEEDRESTART_MODE=a` are already exported by 00_settings.
- Third-party repos use signed-by keyrings (`/usr/share/keyrings` or `/etc/apt/keyrings`),
  as for Sury PHP and GitHub CLI in part 03.
- Any part that `cd`s away must `cd $INSTALLPWD` before returning, because the next part is
  sourced with a relative path.
- Validate before restarting anything that can lock you out (see `sshd -t` in part 05).

### addzhost and the scripts it generates

`addzhost <domain> <git-repo> [<tag>]` (run as the created user, not root) creates
`/var/www/<domain>/{releases,storage,.env,current}`, writes the `puller` and `rollback`
scripts into it, does the first pull, writes an nginx vhost `NN-<domain>.conf`, optionally
runs certbot, and adds the Laravel scheduler to the user's crontab.

`puller` and `rollback` are generated from **unquoted** heredocs:
- `$VAR` is filled in when addzhost runs (e.g. `$WWWSITE`, `$GITREPO`, `$USER`).
- `\$VAR` stays literal and is evaluated when puller runs (e.g. `\$1`, `\$RELEASE_DIR`).
Get this right on every line you touch.

puller flow: `git archive --remote` (or `git clone` for plain `https://github.com` repos) into
`releases/<tag>`, symlink `.env` and `storage`, `composer install --no-dev`, run the app's
`after_deploy` hook if present, fix permissions, swap the `current` symlink, then run
`after_deploy_is_live` if present. `set -e` means a failure leaves the live release alone.

The vhost's PHP version comes from `php -r` at addzhost time, not from `PHPVER`.

## Local deploy tools

`local_support/pusher` and `newversion` are reference copies. The versions the user actually
runs live in `~/local/` on the dev machine, and **`~/local/pusher` is newer than the repo copy**:
it supports a 4th `pusher.conf` column (required PHP version check), a `before_deploy` hook,
and the usage `pusher <env> [<after-deploy-flag>] [<tag>]`. Ask before syncing either way.

## Testing

- There are no automated tests. `shellcheck` is not installed on the dev machine.
- Cheap local check: `bash -n parts/NN_x` (syntax only).
- The real test is running `setup_full` on a fresh Debian 12 or 13 VM. **Never run the parts
  on this Mac**: they need root and Debian, and they rewrite system config.

## Releasing (`pusher_this`)

Run from the repo root on the dev machine: `./pusher_this ["commit message"] [vX.Y.ZZ]`.
It pulls, bumps the version with `newversion -x` (v2.0.13 → v2.0.14), rewrites `VERSION` and
the version strings in README.md (tarball URL, `cd debian-laravel-stack-X`, release badge),
runs `git add --all` + commit + tag, pushes `main` and tags to the public GitHub repo, and
creates a GitHub release with `~/local/githubrelease`.

- It is public and hard to undo. **Only the user runs it.** Don't commit, tag or push unless asked.
- Every change ships as a release, which is why history is mostly `Release vX.Y.ZZ`.
- Keep those three README version strings in their current format, or the `sed` lines in
  `pusher_this` stop matching.

## Notes

- Part 05 step 05.05 (unattended-upgrades + reboot time) uses the same config files as the
  user's `~/local/fleet-autoupdate`, which applies them to existing servers listed in
  `~/local/hosts.txt`. Keep the two in step: `20auto-upgrades`,
  `apt-daily-upgrade.service.d/refresh-lists.conf`, `52auto-reboot`.
