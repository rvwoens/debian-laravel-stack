# ----------------------------------------------------------------------
# addzhost-ssl.sh   --   Lets-Encrypt / certbot helper for addzhost
# ----------------------------------------------------------------------
# Sourced by addzhost:
#     . "$(dirname "$(readlink -f "$0")")/lib/addzhost-ssl.sh"
#
# Exposes one public function:
#
#     request_letsencrypt_cert <servername>
#         Interactively asks the user whether to request a LE cert for
#         the bare domain ($servername) and its www. variant, then runs
#         `certbot --nginx` in non-interactive mode. Falls back to
#         instructive messages on failure / skip so the user knows what
#         to run later by hand.
#
#         Email source order (first non-empty wins):
#           1. interactive prompt
#           2. $CERTBOT_EMAIL environment variable
#
#         Pre-conditions (caller's responsibility):
#           - certbot + python3-certbot-nginx are installed (parts/05_security)
#           - the HTTP vhost is live and reachable on port :80
#             (i.e. addzhost has already run `service nginx restart`)
#           - DNS for $servername and www.$servername points at this box
# ----------------------------------------------------------------------

request_letsencrypt_cert() {
	local servername="$1"

	# ----------------------------------------------------------------------
	# Why HTTP-01 / no wildcard:
	# certbot --nginx uses the HTTP-01 challenge, which can only validate
	# concrete hostnames that resolve to this server on port :80. We deliberately
	# request only `$servername` and `www.$servername`. The nginx vhost
	# server_name still contains `*.$servername` so nginx keeps accepting
	# wildcard subdomain traffic, but those subdomains will not be covered
	# by this certificate -- a wildcard would need DNS-01 with a provider plugin.
	#
	# certbot --nginx will:
	#   1. add `listen 443 ssl;` + ssl_certificate* lines to the matching
	#      server blocks (both the www redirect block and the main block)
	#   2. with --redirect, rewrite the HTTP server to 301 to HTTPS
	# ----------------------------------------------------------------------
	echo "------------------------- Lets Encrypt (certbot) ---------------------------"
	echo "Do you want to request a Lets Encrypt certificate for $servername and www.$servername now? (Y/n)"
	local dossl
	read dossl
	if [ "$dossl" = "n" ] || [ "$dossl" = "N" ]; then
		echo "Skipping certbot. You can run it later with:"
		echo "   sudo certbot --nginx -d $servername -d www.$servername"
		return 0
	fi

	# Ask whether to include www.$servername in the cert. Default Y because
	# most public sites have both A records, but answering N is the right
	# choice when only the apex is DNS-pointed at this server -- certbot
	# would otherwise fail the HTTP-01 challenge on www.* and abort the
	# WHOLE issuance, leaving us with no cert at all.
	echo "Include www.$servername in the certificate as well? (Y/n)"
	#echo "   (answer N if www.$servername has no DNS record pointing here)"
	local dowww
	read dowww
	local include_www=1
	if [ "$dowww" = "n" ] || [ "$dowww" = "N" ]; then
		include_www=0
	fi

	# Allow a default email via the CERTBOT_EMAIL env var (handy for
	# scripted reruns) but always let the user override interactively.
	if [ -n "$CERTBOT_EMAIL" ]; then
		echo "Email for Lets Encrypt registration [$CERTBOT_EMAIL]:"
	else
		echo "Email for Lets Encrypt registration (used for renewal/expiry notices):"
	fi
	local certemail
	read certemail
	if [ -z "$certemail" ]; then
		certemail="$CERTBOT_EMAIL"
	fi
	if [ -z "$certemail" ]; then
		echo "!! No email supplied - skipping certbot. You can re-run later with:"
		if [ "$include_www" -eq 1 ]; then
			echo "   sudo certbot --nginx -d $servername -d www.$servername"
		else
			echo "   sudo certbot --nginx -d $servername"
		fi
		return 1
	fi

	# Apex-only path: user explicitly opted out of www, so a single call.
	if [ "$include_www" -eq 0 ]; then
		if _run_certbot "$certemail" "$servername"; then
			echo "certbot success (apex only) - reloading nginx"
			sudo service nginx reload
			echo "!! NOTE: www.$servername is NOT covered by this certificate."
			echo "!! When you DO want to add it later (after DNS points www. here), run:"
			echo "!!   sudo certbot --nginx -d $servername -d www.$servername --expand --email $certemail --agree-tos"
			return 0
		fi
		echo "!! certbot failed for apex-only - the HTTP vhost is still live, you can retry with:"
		echo "!!   sudo certbot --nginx -d $servername --email $certemail --agree-tos"
		return 1
	fi

	# Apex + www path. Try the full set first, and if that fails (most likely
	# because www.$servername resolves elsewhere or not at all), automatically
	# fall back to apex-only so we still get HTTPS on the bare domain.
	# Note on rate limits: each failed validation counts against the Lets-Encrypt
	# per-domain hourly limit (5/h), but at most 2 attempts here is well within budget.
	if _run_certbot "$certemail" "$servername" "www.$servername"; then
		echo "certbot success (apex + www) - reloading nginx"
		sudo service nginx reload
		return 0
	fi

	echo "!! certbot failed for the apex + www set"
	echo "!! - most likely cause: www.$servername has no DNS record (or points elsewhere)"
	echo "!! Retrying with apex-only ($servername) so you at least get HTTPS on the bare domain..."
	if _run_certbot "$certemail" "$servername"; then
		echo "certbot success (apex only) - reloading nginx"
		sudo service nginx reload
		echo "!! NOTE: www.$servername is NOT covered by this certificate."
		echo "!! Once DNS for www.$servername points at this server, expand the cert with:"
		echo "!!   sudo certbot --nginx -d $servername -d www.$servername --expand --email $certemail --agree-tos"
		return 0
	fi

	echo "!! certbot failed even for apex-only - the HTTP vhost is still live, you can retry with:"
	echo "!!   sudo certbot --nginx -d $servername --email $certemail --agree-tos"
	return 1
}

# ----------------------------------------------------------------------
# _run_certbot <email> <domain1> [<domain2> ...]
#   Internal: builds a `certbot --nginx ... -d ... -d ...` invocation and
#   returns its exit code. Kept separate so we can call it twice (full /
#   apex-only fallback) without duplicating the flag soup.
# ----------------------------------------------------------------------
_run_certbot() {
	local email="$1"; shift
	# Build up the -d args from the remaining positional parameters.
	local d_args=()
	local d
	for d in "$@"; do
		d_args+=(-d "$d")
	done
	# --non-interactive + --agree-tos so we never block on a prompt
	# --redirect makes certbot turn the :80 vhost into a 301 to :443
	# -d order matters: first -d becomes the cert's CN
	sudo certbot --nginx \
		"${d_args[@]}" \
		--non-interactive --agree-tos --redirect \
		--email "$email"
}
