# ----------------------------------------------------------------------
# addzhost-repo.sh   --   helper library for addzhost
# ----------------------------------------------------------------------
# This file is meant to be SOURCED, not executed. addzhost does:
#     . "$(dirname "$(readlink -f "$0")")/lib/addzhost-repo.sh"
# It defines two internal helpers (`_detect_provider`, `_try_autoadd_deploykey`)
# and one public entry point:
#
#     wait_for_git_repo_access $GITREPO $WWWSITE
#         Loops until `git ls-remote` succeeds against the repo. On failure
#         attempts to auto-add this server's pubkey as a Deploy Key via
#         gh / glab (using the github-auth / gitlab-auth helpers in ~/bin),
#         and if that's not possible prints the manual paste-the-pubkey
#         fallback with a R)etry / S)top / C)ontinue prompt.
# ----------------------------------------------------------------------

# ----------------------------------------------------------------------
# _detect_provider <git-url>
#   Sets PROVIDER (github|gitlab|other) and OWNERREPO (owner/repo) from
#   either an ssh url (git@host:owner/repo.git) or an https url
#   (https://host/owner/repo[.git]).
# ----------------------------------------------------------------------
_detect_provider() {
	local url="$1"
	PROVIDER=other
	OWNERREPO=""
	# strip optional trailing .git
	local stripped="${url%.git}"
	if [[ "$stripped" =~ ^git@([^:]+):(.+)$ ]]; then
		local host="${BASH_REMATCH[1]}"
		OWNERREPO="${BASH_REMATCH[2]}"
		case "$host" in
			github.com)  PROVIDER=github ;;
			gitlab.com)  PROVIDER=gitlab ;;
			gitlab*)     PROVIDER=gitlab ;; # self-hosted gitlab.example.com etc.
			github*)     PROVIDER=github ;;
		esac
	elif [[ "$stripped" =~ ^https?://([^/]+)/(.+)$ ]]; then
		local host="${BASH_REMATCH[1]}"
		OWNERREPO="${BASH_REMATCH[2]}"
		case "$host" in
			github.com)  PROVIDER=github ;;
			gitlab.com)  PROVIDER=gitlab ;;
			gitlab*)     PROVIDER=gitlab ;;
			github*)     PROVIDER=github ;;
		esac
	fi
}

# ----------------------------------------------------------------------
# _try_autoadd_deploykey
#   Uses globals MYPUBKEY, GITREPO, WWWSITE. If $GITREPO points at a
#   github / gitlab repo, delegate install + auth of gh/glab to the
#   standalone helpers ~/bin/{github,gitlab}-auth, then call the CLI to
#   add $MYPUBKEY as a read-only Deploy Key on the remote.
#   Returns 0 on success (key added), non-zero otherwise (caller falls
#   back to the manual paste flow).
# ----------------------------------------------------------------------
_try_autoadd_deploykey() {
	# Each early-return tells the user WHY auto-add was skipped, so it
	# is obvious what to fix instead of dropping silently to manual.
	if [ -z "$MYPUBKEY" ]; then
		echo "!! auto-add skipped: no ssh public key found in ~/.ssh/ (id_ed25519.pub / id_rsa.pub)"
		return 1
	fi
	_detect_provider "$GITREPO"
	if [ -z "$OWNERREPO" ]; then
		echo "!! auto-add skipped: could not parse owner/repo from \$GITREPO=$GITREPO"
		echo "!!   expected forms: git@HOST:OWNER/REPO.git   or   https://HOST/OWNER/REPO[.git]"
		return 1
	fi
	if [ "$PROVIDER" = "other" ]; then
		echo "!! auto-add skipped: host in \$GITREPO is neither github* nor gitlab* (no CLI to use)"
		return 1
	fi

	# Re-extract the bare host from $GITREPO so self-hosted github.example.com /
	# gitlab.example.com work and so the deploy-key call hits the right API.
	local host
	if [[ "$GITREPO" =~ ^git@([^:]+): ]]; then
		host="${BASH_REMATCH[1]}"
	elif [[ "$GITREPO" =~ ^https?://([^/]+)/ ]]; then
		host="${BASH_REMATCH[1]}"
	else
		host=""
	fi

	local title="$(hostname)-$(basename "$WWWSITE")"

	case "$PROVIDER" in
		github)
			if ! github-auth "${host:-github.com}"; then
				echo "!! github-auth did not complete - falling back to manual deploy-key paste flow"
				return 1
			fi
			echo -n "Auto-add this server's pubkey as a read-only Deploy Key on ${host:-github.com}/$OWNERREPO ? [Y/n] >" && read yn
			if [ "$yn" = "n" ] || [ "$yn" = "N" ]; then return 1; fi
			# No --allow-write flag means read-only, which is what we want.
			if gh repo deploy-key add "$MYPUBKEY" --title "$title" -R "$OWNERREPO"; then
				echo ">>>> Deploy key uploaded to ${host:-github.com}/$OWNERREPO"
				return 0
			fi
			echo "!! gh failed to add the deploy key (already exists?)"
			return 1
			;;
		gitlab)
			if ! gitlab-auth "${host:-gitlab.com}"; then
				echo "!! gitlab-auth did not complete - falling back to manual deploy-key paste flow"
				return 1
			fi
			echo -n "Auto-add this server's pubkey as a read-only Deploy Key on $OWNERREPO ? [Y/n] >" && read yn
			if [ "$yn" = "n" ] || [ "$yn" = "N" ]; then return 1; fi
			# No --can-push flag means read-only.
			if glab deploy-key add "$MYPUBKEY" --title "$title" -R "$OWNERREPO"; then
				echo ">>>> Deploy key uploaded to $OWNERREPO"
				return 0
			fi
			echo "!! glab failed to add the deploy key (already exists?)"
			return 1
			;;
		*)
			return 1
			;;
	esac
}

# ----------------------------------------------------------------------
# wait_for_git_repo_access <git-url> <wwwsite-path>
#   Public entry point. Loops on `git ls-remote` against the repo,
#   offering auto-add (gh/glab) or manual fallback on failure.
#
#   `git ls-remote --exit-code <url> HEAD` is read-only, works for both
#   ssh:// (git@...) and https:// remotes, and returns non-zero on any
#   access failure. We force `BatchMode=yes` on the ssh side so it fails
#   immediately instead of hanging on a passphrase / password prompt,
#   and `StrictHostKeyChecking=accept-new` so we trust github/gitlab on
#   first contact (with a warning if the key changes later).
#
#   Returns:
#     0  - repo reachable, OK to proceed.
#     1  - user chose Stop.        (caller is expected to exit)
#     2  - user chose Continue anyway (repo not reachable, proceed at own risk).
# ----------------------------------------------------------------------
wait_for_git_repo_access() {
	GITREPO="$1"
	WWWSITE="$2"

	# Pick the pubkey we will offer / upload (prefer ed25519 over rsa).
	if [ -f ~/.ssh/id_ed25519.pub ]; then
		MYPUBKEY=~/.ssh/id_ed25519.pub
	elif [ -f ~/.ssh/id_rsa.pub ]; then
		MYPUBKEY=~/.ssh/id_rsa.pub
	else
		MYPUBKEY=""
	fi

	echo ">>>> Testing git repository access: $GITREPO"
	while true; do
		if GIT_SSH_COMMAND="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new" \
			git ls-remote --exit-code "$GITREPO" HEAD >/dev/null 2>&1; then
			echo ">>>> repo access OK"
			return 0
		fi
		echo ""
		echo "!! Could not reach $GITREPO"

		# Best path first: if gh/glab is installed AND authenticated, offer to
		# add the deploy key in one step. On success we loop back and retest.
		if _try_autoadd_deploykey; then
			echo ">>>> retrying repo access..."
			continue
		fi

		echo "!! Manual fallback: add the following public key as a Deploy Key on the repo:"
		echo "!!   GitLab : Project -> Settings -> Repository -> Deploy keys -> Add deploy key"
		echo "!!   GitHub : Repo    -> Settings -> Deploy keys             -> Add deploy key"
		echo "!! (read-only is enough for pulling; tick 'write' only if puller needs to push)"
		echo "!! Tip: run one of these once to let addzhost auto-add this next time:"
		echo "!!   github-auth                       (installs + auths gh for github.com)"
		echo "!!   gitlab-auth                       (installs + auths glab for gitlab.com)"
		echo "!!   gitlab-auth gitlab.example.com    (for self-hosted GitLab)"
		echo ""
		if [ -n "$MYPUBKEY" ]; then
			echo "------ $MYPUBKEY ------------------------------------"
			cat "$MYPUBKEY"
			echo "-----------------------------------------------------------------"
		else
			echo "!! No public key found in ~/.ssh/ - generate one first with:"
			echo "!!   ssh-keygen -t ed25519 -C \"$USER@$(hostname)\""
		fi
		echo ""
		echo -n "R) Retry  S) Stop  C) Continue anyway [R/s/c] >" && read retry
		case "$retry" in
			s|S) echo "Stopped."; return 1 ;;
			c|C) echo "Continuing despite git access failure - puller will likely fail later"; return 2 ;;
			*) ;; # anything else (incl. just Enter) = retry
		esac
	done
}
