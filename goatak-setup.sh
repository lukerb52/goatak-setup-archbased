#!/usr/bin/env bash
#
# goatak-setup-v2.sh - AUR GoATAK deployment + trusted HTTPS enrollment proxy
#
# What it does:
#   1. asks for hostname, passwords, users and a few options
#   2. creates a CA + server certificate (as the goatak user)
#   3. writes /etc/goatak/goatak_server.yml (old one is backed up)
#   4. sets the web GUI admin password, disables the default `test` user and
#      creates ATAK users (through a temporary localhost-only server instance)
#   5. installs and starts a service (systemd on Arch, runit on Artix/Void)
#   6. builds the ATAK connection data package (<host>_connect.zip)
#   7. optionally opens the firewall (ufw / firewalld)
#
# Existing installations default to a limited enrollment-only repair: certificates,
# accounts, database, TLS stream and service unit are left untouched.
# Full setup still overwrites the generated config/service and should be used cautiously.
#
# Run as normal user: bash goatak-setup.sh
# To repair only: bash goatak-setup.sh --enrollment-only
# To force full setup: bash goatak-setup.sh --full
# Commands that need root go through sudo (or doas), which asks for your password.

set -euo pipefail

# --- fixed paths (match the AUR package) -------------------------------------
BIN=/usr/bin/goatak_server
PKG_CERT=/usr/share/goatak/cert
PKG_DATA=/usr/share/goatak/data
CONF=/etc/goatak/goatak_server.yml
STATE=/var/lib/goatak
SVC_USER=goatak

# Server certificate lifetime for NEW full installs (not public-WebPKI policy).
# Certificate-length limits vary by trust model and client; do not automatically
# replace existing certificates in enrollment-only mode.
SRV_DAYS=825

# ports used by the bootstrap instance (localhost only, stopped afterwards)
BOOT_ADMIN=127.0.0.1:18088
BOOT_API=127.0.0.1:18080
BOOT_LOCAL=127.0.0.1:18888

# --- helpers -----------------------------------------------------------------
c_bold=$'\e[1m'; c_red=$'\e[31m'; c_grn=$'\e[32m'; c_yel=$'\e[33m'; c_off=$'\e[0m'
[[ -t 1 ]] || { c_bold=; c_red=; c_grn=; c_yel=; c_off=; }

step() { printf '\n%s==> %s%s\n' "$c_bold" "$*" "$c_off"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s✓%s %s\n' "$c_grn" "$c_off" "$*"; }
warn() { printf '    %s!%s %s\n' "$c_yel" "$c_off" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

# ask VAR "prompt" [default]
ask() {
    local __var=$1 __prompt=$2 __def=${3-} __ans
    if [[ -n $__def ]]; then
        read -r -p "    $__prompt [$__def]: " __ans || true
        __ans=${__ans:-$__def}
    else
        read -r -p "    $__prompt: " __ans || true
    fi
    printf -v "$__var" '%s' "$__ans"
}

# ask_yn "prompt" y|n  -> returns 0 for yes
ask_yn() {
    local __ans __def=$2 __hint
    [[ $__def == y ]] && __hint="Y/n" || __hint="y/N"
    read -r -p "    $1 [$__hint]: " __ans || true
    __ans=${__ans:-$__def}
    [[ $__ans =~ ^[Yy] ]]
}

# ask_secret VAR "prompt" [default]  (hidden, asked twice)
ask_secret() {
    local __var=$1 __prompt=$2 __def=${3-} __a __b
    while true; do
        if [[ -n $__def ]]; then
            read -r -s -p "    $__prompt (enter = keep default): " __a || true; echo
            if [[ -z $__a ]]; then printf -v "$__var" '%s' "$__def"; return; fi
        else
            read -r -s -p "    $__prompt: " __a || true; echo
        fi
        [[ -n $__a ]] || { warn "must not be empty"; continue; }
        read -r -s -p "    repeat: " __b || true; echo
        [[ $__a == "$__b" ]] || { warn "passwords do not match"; continue; }
        printf -v "$__var" '%s' "$__a"
        return
    done
}

# account passwords go to bcrypt (max 72 bytes) via JSON
valid_account_pw() {
    local p=$1
    (( ${#p} >= 8 )) || { warn "use at least 8 characters"; return 1; }
    (( $(printf '%s' "$p" | wc -c) <= 72 )) || { warn "max 72 bytes"; return 1; }
    [[ ! $p =~ [[:cntrl:]] ]] || { warn "no control characters"; return 1; }
}

json_str() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    printf '"%s"' "$s"
}

# --- privilege helpers ---------------------------------------------------------
# root:        root CMD...
# goatak user: as_goatak CMD...
# goatak user, inside a directory: in_dir DIR CMD...
root()      { "${ROOT[@]}" "$@"; }
as_goatak() { "${ROOT[@]}" -u "$SVC_USER" "$@"; }
# shellcheck disable=SC2016  # $1/$@ are expanded by the inner sh
in_dir()    { as_goatak sh -c 'cd "$1" || exit 1; shift; exec "$@"' sh "$@"; }

# write stdin to a root-owned file: put_file MODE PATH
put_file() {
    local tmpf
    tmpf=$(mktemp "$TMP/put.XXXXXX")
    cat >"$tmpf"
    root install -m "$1" -o root -g root "$tmpf" "$2"
    rm -f "$tmpf"
}

# --- HTTPS enrollment proxy support ------------------------------------------
# Publicly trusted TLS terminates at Nginx on :8446. GoATAK enrollment is
# plain HTTP on :8447, so remote backends MUST travel over a private secure link
# (preferably WireGuard), never a public internet port forward.
ENROLL_MODE=direct
ENROLL_ADDR=":8446"
PROXY_IP=""
PROXY_PEER=""
PROXY_OUTPUT=""
PROXY_CERT=""
PROXY_KEY=""
NGINX_SITE=/etc/nginx/conf.d/goatak-enrollment.conf
MODE_ARG=${1:-}
case "$MODE_ARG" in
    --help|-h)
        cat <<'USAGE'
Usage: bash goatak-setup.sh [--enrollment-only | --full]
  (default): existing installs offer safe enrollment-only migration
  --enrollment-only  Change enrollment listener and ssl.enroll only
  --full             Run complete first-time GoATAK setup (overwrites config)
HTTPS modes: local Nginx, Nginx on another server, or original direct mode.
Never forward plaintext upstream port 8447 to the public internet.
USAGE
        exit 0 ;;
    --enrollment-only|--full|"") ;;
    *) die "unknown argument $MODE_ARG (try --help)" ;;
esac

validate_ip4() {
    python3 - "$1" <<'PYIP'
import ipaddress, sys
try:
    ip=ipaddress.IPv4Address(sys.argv[1])
    cgnat = ip in ipaddress.IPv4Network('100.64.0.0/10')
    assert (ip.is_private or cgnat) and not (ip.is_loopback or ip.is_link_local or ip.is_multicast or ip.is_unspecified or ip.is_reserved)
except (ValueError, AssertionError):
    sys.exit(1)
PYIP
}

# Nginx config is created unprivileged so the same output works on any distro.
# Paths to Let's Encrypt certificate files are resolved on the Nginx machine.
choose_enrollment() {
    step "Quick Connect / enrollment HTTPS"
    info "GoATAK's direct :8446 certificate is signed by its private CA."
    info "For stock iOS Quick Connect choose Nginx with a publicly trusted cert."
    local choice
    while true; do
        ask choice "Proxy: [l]ocal Nginx, [r]emote Nginx, [d]irect private-CA (legacy)" l
        case ${choice,,} in
            l|local)  ENROLL_MODE=local;  ENROLL_ADDR="127.0.0.1:8447"; PROXY_IP=127.0.0.1; break ;;
            r|remote) ENROLL_MODE=remote; break ;;
            d|direct|none) ENROLL_MODE=direct; ENROLL_ADDR=":8446"; break ;;
            *) warn "choose local, remote or direct" ;;
        esac
    done
    if [[ $ENROLL_MODE == remote ]]; then
        info "Use GoATAK's PRIVATE WireGuard/LAN IPv4, not the public IP."
        command -v ip >/dev/null && ip -br -4 addr show 2>/dev/null | sed -n '1,12p' || true
        while true; do
            ask PROXY_IP "GoATAK private IPv4 reachable by remote Nginx" ""
            validate_ip4 "$PROXY_IP" || { warn "enter a private IPv4 address"; continue; }
            # Reject typos / addresses not currently assigned to this host.
            if command -v ip >/dev/null && ! ip -o -4 addr show | grep -Fq "inet $PROXY_IP/"; then
                warn "$PROXY_IP is not assigned to this machine"; continue
            fi
            break
        done
        ENROLL_ADDR="$PROXY_IP:8447"
        while true; do
            ask PROXY_PEER "Remote Nginx's WireGuard/LAN IPv4 (for firewall instructions)" ""
            validate_ip4 "$PROXY_PEER" && break
            warn "enter a private IPv4 address"
        done
        warn "HTTP upstream :8447 MUST be limited to the remote Nginx peer over WireGuard/private LAN."
        warn "Never forward TCP 8447 on your internet router."
    fi
    [[ $ENROLL_MODE == direct ]] && return 0
    PROXY_OUTPUT="$HOME/goatak-enrollment-${HOST}"
    ask PROXY_OUTPUT "Where should Nginx config/instructions be saved?" "$PROXY_OUTPUT"
    [[ $PROXY_OUTPUT == /* ]] || die "proxy output path must be absolute"
    local defcert="/etc/letsencrypt/live/$HOST/fullchain.pem"
    local defkey="/etc/letsencrypt/live/$HOST/privkey.pem"
    info "These PEM paths are on the NGINX computer (not necessarily GoATAK)."
    ask PROXY_CERT "Nginx full-chain certificate path" "$defcert"
    ask PROXY_KEY "Nginx private-key path" "$defkey"
    [[ $PROXY_CERT == /* && $PROXY_KEY == /* && $PROXY_CERT != *[[:space:]]* && $PROXY_KEY != *[[:space:]]* ]] || die "certificate paths must be absolute and have no whitespace"
}

# Standalone, copy/paste guide with explicit machine labels. Nothing here is
# run on the VPS automatically. The user must deploy and verify the VPS config.
make_remote_guide() {
    cat >"$PROXY_OUTPUT/REMOTE-NGINX-SETUP.md" <<EOFGUIDE
# Remote Nginx for GoATAK Quick Connect — $HOST

**Run the installer on the GoATAK desktop, not on the VPS.** The installer
**does not log into or modify the VPS**. It creates this guide and the Nginx
site on the GoATAK desktop, then (only with confirmation) updates GoATAK.

## Your network — write down these three endpoints

| Endpoint | Host/port | Function |
|---|---|---|
| Public enrollment | \`$HOST:8446\` | HTTPS Nginx on VPS; public-trust certificate |
| Backend enrollment | \`$PROXY_IP:8447\` | Plain HTTP on desktop, through private WireGuard/LAN only |
| TAK stream | \`$HOST:8089\` | Existing encrypted GoATAK TCP stream (DO NOT CHANGE) |

Your VPS's **private** WireGuard/LAN source IP: \`$PROXY_PEER\`.
GoATAK desktop's **private** WireGuard/LAN IP: \`$PROXY_IP\`.

Phones use **enrollment port 8446** and **stream port 8089**. Never enter 8447
in OmniTAK. Do not expose 8447 on the public internet or copy GoATAK CA
private keys to your VPS.

## Step 1 — On your GoATAK desktop: copy the generated site to the VPS

The file was generated at:

\`$PROXY_OUTPUT/goatak-enrollment.conf\`

Substitute your VPS SSH user. If SSH is available over WireGuard:

\`\`\`bash
scp "$PROXY_OUTPUT/goatak-enrollment.conf" VPS_USER@$PROXY_PEER:/tmp/goatak-enrollment.conf
\`\`\`

Or copy the file by any secure method. Only the **site configuration** goes
to the VPS; the certificate paths in that file point to files **on the VPS**.

## Step 2 — On your VPS: install the site, verify certificate paths

The VPS must have a publicly trusted full-chain certificate for \`$HOST\`:

\`\`\`text
Certificate: $PROXY_CERT
Private key: $PROXY_KEY
\`\`\`

Use the existing Let's Encrypt certificate if already installed on the VPS.
The script does **not** issue or renew it. Check the paths in the .conf file.

For Debian/Ubuntu/Arch Nginx using \`conf.d/*.conf\` **inside \`http {}\`**:

\`\`\`bash
sudo nginx -T 2>&1 | grep -E 'include .*conf.d|include .*sites-enabled'
if sudo test -e /etc/nginx/conf.d/goatak-enrollment.conf; then
  sudo cp -a /etc/nginx/conf.d/goatak-enrollment.conf "/etc/nginx/conf.d/goatak-enrollment.conf.bak.\$(date +%Y%m%d-%H%M%S)"
fi
sudo install -m 644 /tmp/goatak-enrollment.conf /etc/nginx/conf.d/goatak-enrollment.conf
sudo nginx -t && sudo systemctl reload nginx
sudo ss -lntp | grep ':8446'
\`\`\`

If your Nginx does NOT include that directory, use the included
\`/etc/nginx/sites-enabled\` directory or another included \`http {}\` location.
Do NOT place the site inside a \`stream {}\` block. Use the VPS's init manager
rather than \`systemctl\` if different. If \`nginx -t\` fails, don't reload;
correct the reported problem without touching existing websites.

## Step 3 — On your VPS: remove **old 8446 DNAT**, if applicable

This step is CRITICAL if the VPS previously forwarded public 8446 directly
to GoATAK \`$PROXY_IP:8446\`. The new path is **public 8446 -> VPS Nginx**.
The old DNAT will intercept incoming mobile traffic before Nginx receives it.

Inspect first (read-only):

\`\`\`bash
sudo iptables -t nat -S | grep -- '--dport 8446' || true
sudo nft list ruleset 2>/dev/null | grep -C 2 'dnat to $PROXY_IP:8446' || true
sudo grep -RIn '8446' /etc/wireguard /etc/iptables /etc/systemd/system 2>/dev/null || true
\`\`\`

If \`/etc/wireguard/wg0.conf\` or another WireGuard profile contains a
\`PostUp\`/\`PostDown\` command for this **specific** 8446 DNAT, back up
that configuration and remove ONLY that command. Do not remove commands for
8089, other services, or WireGuard itself. If the line contains multiple
semicolon-separated commands, remove only the 8446 command.

If the live firewall uses the **exact** IPv4 iptables rule below, delete all
matching copies **without restarting WireGuard**:

\`\`\`bash
rule=(-p tcp -m tcp --dport 8446 -j DNAT --to-destination $PROXY_IP:8446)
while sudo iptables -t nat -C PREROUTING "\${rule[@]}" 2>/dev/null; do
  sudo iptables -t nat -D PREROUTING "\${rule[@]}"
done
\`\`\`

Do not execute that deletion if your rule differs. Inspect the applicable
chain, nftables rule and persistent firewall manager instead. The deletion
above is for an exact-match iptables PREROUTING rule; it is NOT a general
firewall cleanup tool. \`iptables-nft\` also shows rules under nftables.

Verify there is no **public 8446 -> $PROXY_IP:8446** DNAT left:

\`\`\`bash
sudo iptables -t nat -S | grep 8446 || true
sudo nft list ruleset 2>/dev/null | grep -C 2 'dnat to $PROXY_IP:8446' || true
sudo ss -lntp | grep ':8446'
\`\`\`

Do not restart WireGuard just to apply this change. Make the persistent change
so the DNAT will not return after a reboot. VPS provider/cloud firewalls must
also allow **inbound TCP 8446 to Nginx**. Existing TCP 8089 forwarding remains.

## Step 4 — On the desktop: enable the GoATAK HTTP enrollment backend

Rerun \`bash goatak-setup-v2.sh --enrollment-only\` (or complete the running
wizard) and select remote Nginx, then confirm the switch once the VPS site
and old DNAT are ready.

The script sets BOTH:

\`\`\`yaml
cert_addr: "$PROXY_IP:8447"
ssl:
  enroll: false
\`\`\`

\`ssl.enroll: false\` is ESSENTIAL: the backend behind Nginx speaks **HTTP**,
not HTTPS. Without this, Nginx may return **HTTP 502**. The script preserves
\`ssl.marti\`, \`ssl.ca\`, \`ssl.cert\`, \`ssl.key\`, account database, CA,
client certificates, and TAK \`8089\`. It backs up GoATAK configuration before
changing it. A restart briefly interrupts existing clients.

Restrict the desktop's TCP 8447 so **only $PROXY_PEER** can reach
\`$PROXY_IP:8447\`, preferably only from the WireGuard interface; do not
WAN-forward 8447. Firewall syntax depends on the desktop's firewall system.

## Step 5 — Verify the WHOLE path, in order

**Run on VPS:** Verify the desktop's backend responds over HTTP:

\`\`\`bash
curl -sS --max-time 8 -o /dev/null -w 'Backend HTTP: %{http_code}\n' \
  http://$PROXY_IP:8447/Marti/api/tls/config
\`\`\`

Expected: **any HTTP response** (often 401 without credentials) confirms
connectivity. A status \`000\` means connection failure. Do not use \`-k\`.

**Run on VPS:** Verify local Nginx can reach that backend and presents a
trusted certificate:

\`\`\`bash
curl -sS --max-time 8 --resolve $HOST:8446:127.0.0.1 \
  -o /dev/null -w 'Nginx HTTP: %{http_code}\nTLS: %{ssl_verify_result}\n' \
  https://$HOST:8446/Marti/api/tls/config
\`\`\`

Expected: **TLS 0**, plus an HTTP response such as \`401\` (unauthenticated
request) or another endpoint response. **HTTP 502** means upstream failure.

**Run on phone using cellular or an independent network:** Open
\`https://$HOST:8446/\` in Safari/Chrome. A 401/404 web response is OK;
timeout/refused/certificate warning is not. Then test OmniTAK Quick Connect
with **enrollment port 8446** and the correct account credentials.

**If local Nginx passes but phones cannot reach it:** inspect old 8446 DNAT,
VPS/cloud INPUT firewall, public IPv4/IPv6 DNS, and traffic with:

\`\`\`bash
sudo tcpdump -ni any 'tcp port 8446'
\`\`\`

Remember that Android hotspot sharing may not share a phone's VPN tunnel with
tethered iPads. The public VPS endpoint should not require the phone to join
WireGuard unless your own firewall is configured to restrict it.

## Rollback / troubleshooting

If Nginx returns 502: check \`ssl.enroll: false\`, GoATAK listener \`$PROXY_IP:8447\`,
Nginx \`proxy_pass http://$PROXY_IP:8447;\`, and desktop firewall.

If Android says **HTTP 401**, the endpoint was reached; check account
credentials only if the **authenticated Quick Connect attempt** gets 401.
A manual \`curl\` without credentials can normally get 401.

If clients get connection refused: check active DNAT for old 8446, public
firewall and Nginx listening with \`ss -lntp\`.

To roll back, restore the latest pre-change copy of
\`/etc/goatak/goatak_server.yml.bak.*\` on the **desktop**, restart GoATAK,
AND restore the previous forwarding path on the VPS if you wish to return to
direct GoATAK 8446. Do not restore outdated port-forward rules unless GoATAK
is once again listening there. Back up current configs before rollback.

**IMPORTANT:** This guide does not run any remote commands. No changes are made
to your VPS until YOU copy and install the config and adjust the forwarding.
EOFGUIDE
}

make_proxy_files() {
    [[ $ENROLL_MODE == direct ]] && return 0
    mkdir -p "$PROXY_OUTPUT"
    [[ -w $PROXY_OUTPUT ]] || die "cannot write $PROXY_OUTPUT"
    cat >"$PROXY_OUTPUT/goatak-enrollment.conf" <<EOFNG
# GoATAK Quick Connect HTTPS enrollment. Install inside nginx http{}.
# Generated for $HOST; private GoATAK upstream is $PROXY_IP:8447.
server {
    listen 8446 ssl;
    server_name $HOST;
    ssl_certificate $PROXY_CERT;
    ssl_certificate_key $PROXY_KEY;
    ssl_protocols TLSv1.2 TLSv1.3;
    client_max_body_size 16m;

    location / {
        proxy_pass http://$PROXY_IP:8447;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_connect_timeout 10s;
        proxy_read_timeout 60s;
    }
}
EOFNG
    cat >"$PROXY_OUTPUT/README.txt" <<EOFRD
GoATAK HTTPS enrollment proxy
=============================
Host shown to phones: $HOST
Nginx installation: $ENROLL_MODE
GoATAK enrollment backend: $ENROLL_ADDR (HTTP on port 8447)
Public/phone-facing HTTPS: $HOST:8446 (Nginx)
Encrypted TAK client stream: $HOST:8089 (GoATAK; unchanged)

IMPORTANT FOR REMOTE NGINX: Read REMOTE-NGINX-SETUP.md first. It gives
explicit DESKTOP vs VPS steps, secure copy commands, WireGuard PostUp/PostDown
changes, how to remove the obsolete public :8446 DNAT, and end-to-end tests.
In proxy modes, GoATAK MUST use ssl.enroll: false (HTTP backend :8447).

1. Acquire a PUBLICLY TRUSTED TLS full chain and key for $HOST on the
   Nginx computer. The configured paths are:
   $PROXY_CERT
   $PROXY_KEY
   Let's Encrypt with DNS-01 works without inbound port 80; choose your DNS
   provider's certbot DNS plugin (or another ACME client). Arrange automatic
   renewal AND Nginx reload. Do not copy the GoATAK private CA key here.
2. Install goatak-enrollment.conf into an
   included Nginx http{} conf directory, typically /etc/nginx/conf.d/.
   Example, on the Nginx host:
      sudo install -m 644 goatak-enrollment.conf /etc/nginx/conf.d/goatak-enrollment.conf
      sudo nginx -t
      sudo systemctl reload nginx    # or start nginx if not running
3. Check from a machine that reaches the Nginx listener:
      openssl s_client -connect $HOST:8446 -servername $HOST \\
        -verify_hostname $HOST -verify_return_error </dev/null 2>&1 \\
        | grep -E 'Verification:|Verify return code:|verify error:'
   Success: Verify return code: 0 (ok), WITHOUT -CAfile.
4. Add an OmniTAK iOS Quick Connect to $HOST (server 8089, enroll 8446).

NETWORK / WIREGUARD
- Do not forward 8447 on your WAN/router.
- Existing WireGuard UDP forwarding need not be changed.
- iOS clients must reach Nginx TCP 8446 and GoATAK TCP 8089.
- $([[ $ENROLL_MODE == remote ]] && echo "Remote Nginx must reach GoATAK $PROXY_IP:8447; allow ONLY $PROXY_PEER as source, preferably restricted to wg0." || echo "Local Nginx reaches 127.0.0.1:8447; never open 8447 in the firewall.")
- DNS for $HOST must point/routably resolve to the Nginx machine for 8446,
  and to GoATAK for 8089. If they are separate machines, use appropriate
  port-specific routing/NAT, distinct internal routing, or a front-end TCP
  proxy for 8089. DNS alone cannot send different ports to different servers.
- The optional file OPTIONAL-stream-8089.conf is an Nginx stream{} snippet for
  raw TCP pass-through of :8089 to GoATAK (requires Nginx stream module). ONLY
  use it if the clients connect to Nginx for both :8446 and :8089; do not
  install it into http{} or enable it if existing 8089 routing already works.
- When both hosts are on WireGuard, use suitable routes/port forwards between
  Nginx and GoATAK and ensure both can communicate across the VPN.
$([[ $ENROLL_MODE == remote ]] && echo "- UFW example on GoATAK, assuming wg0: sudo ufw allow in on wg0 from $PROXY_PEER to $PROXY_IP port 8447 proto tcp" || echo "- No firewall port for 8447 is needed with local loopback Nginx.")
- Do not expose GoATAK's admin HTTP API or enrollment HTTP backend publicly.
EOFRD
    if [[ $ENROLL_MODE == remote ]]; then
        make_remote_guide
        cat >"$PROXY_OUTPUT/OPTIONAL-stream-8089.conf" <<EOFSTREAM
# OPTIONAL only when client DNS points to Nginx and :8089 needs forwarding.
# This file belongs inside Nginx's STREAM context, NOT its HTTP context.
# The Nginx stream module must be installed/enabled on the Nginx computer.
server {
    listen 8089;
    proxy_connect_timeout 10s;
    proxy_timeout 1h;
    proxy_pass $PROXY_IP:8089;
}
EOFSTREAM
    fi
    ok "Nginx site and notes generated at $PROXY_OUTPUT/"
}

# Test certificate on LOCAL nginx computer before touching an existing GoATAK.
local_cert_ready() {
    command -v nginx >/dev/null || { warn "nginx not installed on this GoATAK host"; return 1; }
    root test -r "$PROXY_CERT" && root test -r "$PROXY_KEY" || {
        warn "Nginx certificate/key not found. Acquire a public-trust certificate first."
        return 1
    }
    root openssl x509 -in "$PROXY_CERT" -noout -checkend 86400 >/dev/null 2>&1 || {
        warn "Nginx certificate invalid or expires in less than 24 hours"; return 1;
    }
    root openssl x509 -in "$PROXY_CERT" -noout -checkhost "$HOST" 2>/dev/null | grep -Eqi 'does match|does match certificate' || {
        warn "Nginx certificate does not match $HOST"; return 1;
    }
    local cert_pub key_pub
    cert_pub=$(root openssl x509 -in "$PROXY_CERT" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256) || return 1
    key_pub=$(root openssl pkey -in "$PROXY_KEY" -pubout -outform DER 2>/dev/null | openssl dgst -sha256) || return 1
    [[ $cert_pub == "$key_pub" && -n $cert_pub ]] || {
        warn "Nginx certificate and private key do not match"; return 1;
    }
    # An unknown/private CA is not the intended Quick Connect fix.
    if ! root openssl verify -CApath /etc/ssl/certs -untrusted "$PROXY_CERT" "$PROXY_CERT" >/dev/null 2>&1; then
        warn "Nginx certificate does NOT validate against this host's public/system CAs."
        warn "Use a trusted CA full chain (e.g. Let's Encrypt), not GoATAK's private CA."
        return 1
    fi
    # Nginx might be configured differently; ensure the include directory is active.
    root nginx -T 2>&1 | grep -Eq '^[[:space:]]*include[[:space:]]+/etc/nginx/conf\.d/\*\.conf;' || {
        warn "Nginx may not include /etc/nginx/conf.d/*.conf; configure your http{} include first."
        return 1
    }
}

backup_conf() {
    BACKUP_CONF="${CONF}.bak.$(date +%Y%m%d-%H%M%S).$$"
    root cp -p "$CONF" "$BACKUP_CONF"
    ok "config backup: $BACKUP_CONF"
}

# Patch ONLY cert_addr and ssl.enroll. Plain HTTP upstream is required behind
# trusted-HTTPS Nginx; all existing stream / CA settings are preserved.
patch_enrollment_config() {
    root python3 - "$CONF" "$ENROLL_ADDR" <<'PYPATCH'
from pathlib import Path
import os, re, sys, tempfile

path, addr = Path(sys.argv[1]), sys.argv[2]
if not re.fullmatch(r'(?:(?:127\.0\.0\.1|[0-9]{1,3}(?:\.[0-9]{1,3}){3}):8447)',addr):
    raise SystemExit('refusing unsafe cert_addr')

src = path.read_text()
lines = src.splitlines(keepends=True)
# Do not accidentally mutate a YAML document with aliases, flow-style ssl
# blocks, duplicate top-level keys or multiple documents.
if re.search(r'^\s*---\s*$', src, re.M) and len(re.findall(r'^---\s*$', src, re.M)) > 1:
    raise SystemExit('multiple YAML documents; manual review needed')

def top_key(line, key):
    return bool(re.match(r'^' + re.escape(key) + r'\s*:', line))

cert_ids = [i for i, line in enumerate(lines) if top_key(line, 'cert_addr')]
ssl_ids = [i for i, line in enumerate(lines) if top_key(line, 'ssl')]
if len(cert_ids) > 1 or len(ssl_ids) > 1:
    raise SystemExit('duplicate cert_addr or ssl sections; manual review needed')

if cert_ids:
    i = cert_ids[0]
    prefix = re.match(r'^(cert_addr\s*:\s*)', lines[i]).group(1)
    lines[i] = prefix + '"' + addr + '"\n'
else:
    lines.append('cert_addr: "' + addr + '"\n')

if ssl_ids:
    first = ssl_ids[0]
    if not re.match(r'^ssl\s*:\s*(?:#.*)?$', lines[first].rstrip('\n')):
        raise SystemExit('ssl section uses unsupported inline YAML; manual review needed')
    end = first + 1
    while end < len(lines):
        line = lines[end]
        if re.match(r'^[^\s#][^\n]*:', line) or re.match(r'^---\s*$', line):
            break
        end += 1
    enroll_ids = [i for i in range(first+1, end)
                  if re.match(r'^  enroll\s*:', lines[i])]
    if len(enroll_ids) > 1:
        raise SystemExit('duplicate ssl.enroll settings; manual review needed')
    if enroll_ids:
        i = enroll_ids[0]
        lines[i] = re.match(r'^(\s*enroll\s*:\s*)', lines[i]).group(1) + 'false\n'
    else:
        lines.insert(end, '  enroll: false\n')
else:
    lines.append('\nssl:\n  enroll: false\n')

new = ''.join(lines)
if new == src:
    sys.exit(0)
st = os.stat(path)
fd, name = tempfile.mkstemp(prefix='.goatak-', dir=str(path.parent))
try:
    os.fchmod(fd, st.st_mode & 0o777)
    os.fchown(fd, st.st_uid, st.st_gid)
    with os.fdopen(fd, 'w') as f:
        f.write(new)
        f.flush()
        os.fsync(f.fileno())
    os.replace(name, path)
except BaseException:
    try: os.unlink(name)
    except OSError: pass
    raise
PYPATCH
}

# If the system is already correctly configured (e.g. running again solely to
# regenerate remote VPS notes), do not rewrite config or restart working TAK.
enrollment_already_configured() {
    root python3 - "$CONF" "$ENROLL_ADDR" <<'PYCHECK'
from pathlib import Path
import re,sys
text=Path(sys.argv[1]).read_text()
addr=sys.argv[2]
cert=re.search(r'^cert_addr\s*:\s*["\']?([^\n"\' #]+)',text,re.M)
ssl=re.search(r'^ssl\s*:\s*(?:#.*)?\n((?:^[ \t]+.*\n|^\s*\n|^#.*\n)*)',text,re.M)
if not cert or cert.group(1) != addr or not ssl:
    sys.exit(1)
if not re.search(r'^  enroll\s*:\s*false\b',ssl.group(1),re.M):
    sys.exit(1)
PYCHECK
}
restart_running_goatak() {
    if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null; then
        root systemctl restart goatak.service && root systemctl is-active --quiet goatak.service
    elif command -v sv >/dev/null; then
        root sv restart goatak
    else
        warn "no supported init manager detected; restart GoATAK manually"
        return 1
    fi
}

wait_for_goatak() {
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if ss -ltnH 'sport = :8089' 2>/dev/null | grep -q . && \
           ss -ltnH 'sport = :8447' 2>/dev/null | grep -q .; then
            return 0
        fi
        sleep 1
    done
    warn "GoATAK did not open both :8089 and :8447 after restart"
    return 1
}

# Install or replace only this dedicated Nginx site; roll it back if nginx -t fails.
install_local_site() {
    local site_backup="" site_appeared=0
    if root test -e "$NGINX_SITE"; then
        site_backup="${NGINX_SITE}.bak.$(date +%Y%m%d-%H%M%S).$$"
        root cp -p "$NGINX_SITE" "$site_backup"
    else
        site_appeared=1
    fi
    root install -d -m 755 "$(dirname "$NGINX_SITE")"
    root install -m 644 "$PROXY_OUTPUT/goatak-enrollment.conf" "$NGINX_SITE"
    if ! root nginx -t; then
        if [[ -n $site_backup ]]; then root cp -p "$site_backup" "$NGINX_SITE"; else root rm -f "$NGINX_SITE"; fi
        die "Nginx config validation failed; restored Nginx config, GoATAK unchanged"
    fi
    NGINX_BACKUP="$site_backup"
    NGINX_NEW="$site_appeared"
}

rollback_local_site() {
    if [[ -n ${NGINX_BACKUP:-} ]]; then
        root cp -p "$NGINX_BACKUP" "$NGINX_SITE"
    elif [[ ${NGINX_NEW:-0} == 1 ]]; then
        root rm -f "$NGINX_SITE"
    fi
    root nginx -t >/dev/null 2>&1 && root systemctl reload nginx 2>/dev/null || true
}

run_enrollment_only() {
    root test -f "$CONF" || die "not found: $CONF (run --full to install first)"
    step "Enrollment-only repair (preserves existing GoATAK install)"
    info "Will not regenerate CA, stream TLS certs, devices, accounts or database."
    # Extract an existing stream certificate's first DNS SAN as a helpful default.
    local guessed host_default
    guessed=$(root python3 - "$CONF" <<'PYHOST'
import re,sys
from pathlib import Path
try:
    text=Path(sys.argv[1]).read_text()
    match=re.search(r'^\s+cert:\s*["\']?([^\s"\']+)', text, re.M)
    print(match.group(1) if match else '')
except (OSError, ValueError):
    print('')
PYHOST
)
    host_default="$(hostname -f 2>/dev/null || hostname)"
    if [[ -n $guessed ]] && root test -f "$guessed"; then
        local dns
        dns=$(root openssl x509 -in "$guessed" -noout -ext subjectAltName 2>/dev/null | sed -n 's/.*DNS:\([^, ]*\).*/\1/p' | head -n 1) || true
        [[ -n $dns ]] && host_default="$dns"
    fi
    ask HOST "Existing public server hostname" "$host_default"
    [[ $HOST =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]] || die "invalid hostname"
    choose_enrollment
    if [[ $ENROLL_MODE == direct ]]; then
        info "Leaving direct-GoATAK enrollment unchanged; no changes made."
        return 0
    fi
    make_proxy_files
    if [[ $ENROLL_MODE == local ]]; then
        if ! local_cert_ready; then
            warn "No changes were made to GoATAK. Fix local Nginx/certificate, then rerun."
            info "Instructions: $PROXY_OUTPUT/README.txt"
            return 0
        fi
        if ! ask_yn "Install local Nginx site AND switch GoATAK enrollment to 127.0.0.1:8447?" y; then
            info "Nothing modified on GoATAK; generated files are ready."
            return 0
        fi
        install_local_site
    else
        if enrollment_already_configured; then
            ok "GoATAK already uses HTTP enrollment $ENROLL_ADDR (ssl.enroll=false)"
            info "Generated updated VPS site and instructions: $PROXY_OUTPUT/REMOTE-NGINX-SETUP.md"
            info "No GoATAK config change or service restart was needed."
            return 0
        fi
        step "Remote VPS deployment — required before changing GoATAK"
        info "Detailed guide: $PROXY_OUTPUT/REMOTE-NGINX-SETUP.md"
        info "1. DESKTOP: scp '$PROXY_OUTPUT/goatak-enrollment.conf' VPS_USER@$PROXY_PEER:/tmp/"
        info "2. VPS: install into included nginx http{} directory; nginx -t && reload."
        info "3. VPS: REMOVE OLD DNAT public :8446 -> $PROXY_IP:8446 from live firewall"
        info "   AND persistent WireGuard PostUp/PostDown (if present). Keep :8089 forwarding!"
        info "4. VPS: check nginx listening :8446. GoATAK switch below enables HTTP backend."
        warn "The VPS was NOT changed by this script. Never public-forward :8447."
        if ! ask_yn "VPS Nginx installed AND obsolete 8446 DNAT removed? Switch GoATAK backend NOW?" n; then
            info "No GoATAK settings changed. Read remote guide and rerun when ready."
            return 0
        fi
    fi
    backup_conf
    if ! patch_enrollment_config; then
        [[ $ENROLL_MODE == local ]] && rollback_local_site
        die "could not update $CONF; original preserved in $BACKUP_CONF"
    fi
    if ! restart_running_goatak || ! wait_for_goatak; then
        warn "GoATAK restart/port check failed; restoring previous config"
        root cp -p "$BACKUP_CONF" "$CONF"
        restart_running_goatak || warn "automatic recovery failed; inspect service logs"
        [[ $ENROLL_MODE == local ]] && rollback_local_site
        die "GoATAK restart failed; rolled back config"
    fi
    if [[ $ENROLL_MODE == local ]]; then
        local nginx_ok=0
        if command -v systemctl >/dev/null && [[ -d /run/systemd/system ]]; then
            if root systemctl is-active --quiet nginx; then
                root systemctl reload nginx && nginx_ok=1
            else
                root systemctl start nginx && nginx_ok=1
            fi
        elif command -v sv >/dev/null; then
            root sv restart nginx && nginx_ok=1
        fi
        if (( ! nginx_ok )); then
            warn "Nginx could not start/reload; restoring original GoATAK enrollment"
            root cp -p "$BACKUP_CONF" "$CONF"
            restart_running_goatak || warn "manual restart required"
            rollback_local_site
            die "reverted changes due to Nginx failure"
        fi
    fi
    ok "GoATAK cert_addr now: $ENROLL_ADDR (ssl.enroll: false — HTTP backend)"
    info "Streaming :8089, client certs, DB and user accounts were not altered."
    info "Check: sudo ss -lntp | grep -E ':(8089|8446|8447)\\b'"
    info "Test from a reachable host using OpenSSL WITHOUT -CAfile (instructions in README)."
    [[ $ENROLL_MODE == remote ]] && warn "Set VPN firewall: allow TCP $PROXY_IP:8447 ONLY from $PROXY_PEER; no WAN forward."
    info "If iOS still rejects :8089, import the GoATAK CA via OmniTAK's built-in truststore/connection package."
}

# --- preflight -----------------------------------------------------------------
[[ $EUID -ne 0 ]] || die "run this as your normal user, not root - it calls sudo itself"
[[ -x $BIN ]] || die "$BIN not found - install the goatak package first"
[[ -d $PKG_CERT ]] || die "$PKG_CERT not found - is the goatak package installed?"
for cmd in openssl curl ss sed mktemp python3; do
    command -v "$cmd" >/dev/null || die "missing command: $cmd"
done
command -v zip >/dev/null || die "missing command: zip (pacman -S zip)"

if command -v sudo >/dev/null; then
    ROOT=(sudo); ROOT_NAME=sudo
elif command -v doas >/dev/null; then
    ROOT=(doas); ROOT_NAME=doas
else
    die "neither sudo nor doas found"
fi

# processes started as goatak must not inherit an unreadable working directory
cd /

TMP=$(mktemp -d)
chmod 755 "$TMP"
KEEPALIVE_PID=""
cleanup() {
    stop_bootstrap 2>/dev/null || true
    [[ -n $KEEPALIVE_PID ]] && kill "$KEEPALIVE_PID" 2>/dev/null
    rm -rf "$TMP"
}
stop_bootstrap() {
    [[ -f $TMP/bootstrap.yml ]] || return 0
    as_goatak pkill -f -- "-config $TMP/bootstrap.yml" 2>/dev/null || true
}
trap cleanup EXIT

# init system
if [[ -d /run/systemd/system ]]; then
    INIT=systemd
elif command -v sv >/dev/null && [[ -d /etc/runit/sv ]]; then
    INIT=runit; SV_DIR=/etc/runit/sv/goatak; SV_LINK=/run/runit/service/goatak   # Artix
elif command -v sv >/dev/null && [[ -d /etc/sv ]]; then
    INIT=runit; SV_DIR=/etc/sv/goatak; SV_LINK=/var/service/goatak               # Void
else
    INIT=none
fi

cat <<EOF

${c_bold}GoATAK setup${c_off}
This configures TLS, users and a service for the goatak server.
Init system detected: ${INIT}

Root rights are needed to check the existing state in $STATE and, later,
to write config, certificates and the service. $ROOT_NAME will ask for your
password now; the script keeps that session alive until it finishes.
Nothing is changed until you confirm the summary.
EOF

step "Authenticating with $ROOT_NAME"
if [[ $ROOT_NAME == sudo ]]; then
    sudo -v || die "sudo authentication failed"
    # refresh sudo's timestamp while we run, so it doesn't ask again mid-way
    ( while sleep 50; do sudo -n -v 2>/dev/null || exit; done ) &
    KEEPALIVE_PID=$!
else
    doas true || die "doas authentication failed"
    info "tip: 'permit persist' in /etc/doas.conf avoids repeated password prompts"
fi
ok "ok"

if [[ $MODE_ARG == --enrollment-only ]] || { [[ $MODE_ARG != --full ]] && root test -f "$CONF" && ask_yn "Existing GoATAK config found. Only repair HTTPS enrollment (recommended)?" y; }; then
    run_enrollment_only
    exit 0
fi

if ! id "$SVC_USER" >/dev/null 2>&1; then
    step "Creating system user $SVC_USER"
    if [[ -f /usr/lib/sysusers.d/goatak.conf ]] && command -v systemd-sysusers >/dev/null; then
        root systemd-sysusers /usr/lib/sysusers.d/goatak.conf
    else
        root useradd -r -d "$STATE" -s /usr/bin/nologin "$SVC_USER"
    fi
    id "$SVC_USER" >/dev/null 2>&1 || die "could not create user $SVC_USER"
    ok "$SVC_USER"
fi

# --- questions -----------------------------------------------------------------
step "Server identity"
while true; do
    ask HOST "Hostname phones will connect to (e.g. tak.example.com)" "$(hostname -f 2>/dev/null || cat /etc/hostname 2>/dev/null || true)"
    [[ $HOST =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] && break
    warn "letters, digits, dots and dashes only"
done
ask EXTRA_SANS "Extra names/IPs for the certificate, space separated (optional)" ""
for n in $EXTRA_SANS; do
    [[ $n =~ ^[A-Za-z0-9.:-]+$ ]] || die "invalid name/IP: $n"
done

choose_enrollment

step "Certificate storage"
ask CERT_DIR "Directory for CA and server certificates" "$STATE/cert/files"
[[ $CERT_DIR == /* ]] || die "use an absolute path"

info "Password for the .p12 truststore files. It only protects public CA certificates"
info "and is embedded in the connection package, so the default is acceptable."
while true; do
    ask_secret P12_PASS "p12 password" "atakatak"
    [[ $P12_PASS =~ ^[A-Za-z0-9._@%+=,:-]+$ ]] && break
    warn "use letters, digits and . _ @ % + = , : - only (it is embedded in shell and XML)"
done

REGEN=1; RENEW=0
if root test -f "$CERT_DIR/$HOST.pem" && root test -f "$CERT_DIR/$HOST.key"; then
    if ask_yn "A server certificate for $HOST already exists. Reuse it?" y; then
        REGEN=0
        # Renewing keeps the key: goatak signs enrolled devices' certificates with
        # it, so a new key would make every enrolled device enroll again.
        dates=$(root openssl x509 -in "$CERT_DIR/$HOST.pem" -noout -startdate -enddate)
        not_before=$(date -d "$(sed -n 's/^notBefore=//p' <<<"$dates")" +%s)
        not_after=$(date -d "$(sed -n 's/^notAfter=//p' <<<"$dates")" +%s)
        lifetime=$(( (not_after - not_before) / 86400 ))
        days_left=$(( (not_after - $(date +%s)) / 86400 ))
        if (( lifetime > SRV_DAYS )); then
            warn "existing certificate lifetime: $lifetime days; some clients impose different limits"
            ask_yn "Renew certificate with same key? (may affect clients; default NO)" n && RENEW=1
        elif (( days_left < 60 )); then
            warn "it expires in $days_left days"
            ask_yn "Renew certificate with same key? (may affect clients; default NO)" n && RENEW=1
        fi
    fi
fi

step "Connection package"
ask ZIP_DIR "Where should the ATAK connection zip be saved?" "$HOME"
ZIP_DIR=${ZIP_DIR/#\~/$HOME}
[[ $ZIP_DIR == /* ]] || die "use an absolute path"
[[ ! -e $ZIP_DIR || ( -d $ZIP_DIR && -w $ZIP_DIR ) ]] || die "cannot write to $ZIP_DIR"

step "Network"
if ask_yn "Web GUI (port 8088) on localhost only? (reach it via ssh -L 8088:localhost:8088)" y; then
    ADMIN_ADDR="127.0.0.1:8088"
else
    ADMIN_ADDR=":8088"
    warn "the web GUI is plain HTTP - passwords will cross the network unencrypted"
fi
if ask_yn "Disable unencrypted CoT on port 8999 (TCP/UDP)?" y; then
    PLAIN_TCP='""'; PLAIN_UDP='""'
else
    PLAIN_TCP='":8999"'; PLAIN_UDP='":8999"'
fi

step "Accounts"
FRESH_DB=1
root test -f "$STATE/db.sqlite" && FRESH_DB=0
if (( FRESH_DB )); then
    info "New database: the server creates admin/admin and test/111111 on first start."
    info "This script replaces the admin password and disables 'test'."
    CUR_ADMIN_PW="admin"
else
    info "Existing database found in $STATE - it is kept."
    read -r -s -p "    Current web GUI admin password (enter = skip account changes): " CUR_ADMIN_PW || true; echo
fi

DO_ACCOUNTS=0; NEW_ADMIN_PW=""; USERS=(); PASSES=(); SCOPES=()
if [[ -n $CUR_ADMIN_PW ]]; then
    DO_ACCOUNTS=1
    if (( FRESH_DB )) || ask_yn "Change the admin password?" n; then
        while true; do
            ask_secret NEW_ADMIN_PW "New web GUI admin password"
            valid_account_pw "$NEW_ADMIN_PW" && break
        done
    fi
    info "Add ATAK users (one per person; the name ends up in their certificate)."
    while true; do
        ask u "Username (empty = done)" ""
        [[ -z $u ]] && break
        [[ $u =~ ^[A-Za-z0-9._-]+$ ]] || { warn "letters, digits, . _ - only"; continue; }
        [[ $u == admin || $u == test ]] && { warn "'$u' is reserved"; continue; }
        while true; do
            ask_secret p "Password for $u"
            valid_account_pw "$p" && break
        done
        ask s "Scope for $u (users only see others in the same scope)" "default"
        [[ $s =~ ^[A-Za-z0-9._-]+$ ]] || { warn "invalid scope, using 'default'"; s=default; }
        USERS+=("$u"); PASSES+=("$p"); SCOPES+=("$s")
    done
    (( ${#USERS[@]} )) || warn "no ATAK users added - add them later in the web GUI (Devices)"
fi

FW=none
if command -v ufw >/dev/null && root ufw status 2>/dev/null | grep -q "Status: active"; then
    FW=ufw
elif command -v firewall-cmd >/dev/null && root firewall-cmd --state >/dev/null 2>&1; then
    FW=firewalld
fi
OPEN_FW=0
if [[ $FW != none ]]; then
    step "Firewall"
    if [[ $ENROLL_MODE == remote ]]; then
        ask_yn "Open 8089 and 8443/tcp in $FW? (8447 restricted manually)" n && OPEN_FW=1
    else
        ask_yn "Open 8089, 8443 and 8446/tcp in $FW? (VPN users may not need this)" n && OPEN_FW=1
    fi
fi

# --- summary -------------------------------------------------------------------
step "Summary"
info "hostname:        $HOST ${EXTRA_SANS:+(+ $EXTRA_SANS)}"
if (( REGEN )); then cert_action="new server cert, $SRV_DAYS days"
elif (( RENEW )); then cert_action="renew server cert for $SRV_DAYS days, same key"
else cert_action="reuse server cert"; fi
info "certificates:    $CERT_DIR ($cert_action)"
info "connection zip:  $ZIP_DIR/${HOST}_connect.zip"
info "config:          $CONF (existing file is backed up)"
info "web GUI:         $ADMIN_ADDR"
info "plain CoT 8999:  $([[ $PLAIN_TCP == '""' ]] && echo disabled || echo enabled)"
info "TLS ports:       8089 (CoT), 8443 (API), 8446 (enrollment via $ENROLL_MODE)"
info "enrollment:      GoATAK $ENROLL_ADDR; Nginx $([[ $ENROLL_MODE == direct ]] && echo none || echo "$PROXY_OUTPUT")"
if (( DO_ACCOUNTS )); then
    info "admin password:  $([[ -n $NEW_ADMIN_PW ]] && echo change || echo keep)"
    info "new users:       ${USERS[*]:-none}"
else
    info "accounts:        unchanged"
fi
info "service:         $INIT"
info "firewall:        $([[ $OPEN_FW == 1 ]] && echo "open ports in $FW" || echo "no changes")"
ask_yn "Proceed?" y || die "aborted"

# --- work ----------------------------------------------------------------------
step "Stopping existing service"
case $INIT in
    systemd) root systemctl stop goatak.service 2>/dev/null || true ;;
    runit)   if [[ -e $SV_LINK ]]; then root sv down goatak 2>/dev/null || true; fi ;;
esac
ok "done"

step "State directory"
root install -d -o "$SVC_USER" -g "$SVC_USER" -m 750 "$STATE"
if ! root test -d "$STATE/data"; then
    root cp -r "$PKG_DATA" "$STATE/data"
    root chown -R "$SVC_USER:$SVC_USER" "$STATE/data"
fi
root install -d -o "$SVC_USER" -g "$SVC_USER" -m 750 "$CERT_DIR"
# make sure goatak can reach CERT_DIR if it lives outside $STATE
d=$(dirname "$CERT_DIR")
while [[ $d != / && $d != "$STATE" ]]; do
    as_goatak test -x "$d" || die "goatak cannot enter $d - pick another certificate directory"
    d=$(dirname "$d")
done
ok "$STATE"

step "Certificates"
# private copy of the package scripts with our p12 password (packaged files stay untouched)
cp "$PKG_CERT"/*.sh "$TMP/"
sed -i "s/^PASS=.*/PASS='$P12_PASS'/" "$TMP/params.sh"
sed -i "s/-days 3650/-days $SRV_DAYS/" "$TMP/make_server_cert.sh"
grep -q -- "-days $SRV_DAYS" "$TMP/make_server_cert.sh" \
    || die "could not set the server certificate lifetime in $PKG_CERT/make_server_cert.sh (package changed?)"
chmod 755 "$TMP"/*.sh

if root test -f "$CERT_DIR/ca.key"; then
    # refresh the truststore so it matches the chosen password
    in_dir "$CERT_DIR" openssl pkcs12 -export -nokeys -name ca -in ca.pem -out truststore.p12 -passout "pass:$P12_PASS"
    ok "CA exists, reusing $CERT_DIR/ca.pem"
else
    in_dir "$CERT_DIR" "$TMP/make_ca.sh" >/dev/null 2>&1 || die "CA creation failed"
    ok "CA created"
fi

if (( REGEN )); then
    in_dir "$CERT_DIR" rm -f "$HOST.pem" "$HOST.key"
    # shellcheck disable=SC2086  # EXTRA_SANS is intentionally word-split
    in_dir "$CERT_DIR" "$TMP/make_server_cert.sh" "$HOST" $EXTRA_SANS >/dev/null 2>&1 \
        || die "server certificate creation failed"
    ok "server certificate created for $HOST ($SRV_DAYS days)"
elif (( RENEW )); then
    # Same key and subject, new lifetime. Keep the old names and add any new ones.
    sans=()
    while read -r san; do
        [[ -n $san ]] && sans+=("${san/#IP Address:/IP:}")
    done < <(root openssl x509 -in "$CERT_DIR/$HOST.pem" -noout -ext subjectAltName 2>/dev/null \
                 | tail -n +2 | tr ',' '\n' | sed 's/^ *//')
    for n in "$HOST" $EXTRA_SANS; do
        if [[ $n =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ || $n == *:* ]]; then sans+=("IP:$n"); else sans+=("DNS:$n"); fi
    done
    san_list=$(printf '%s\n' "${sans[@]}" | awk '!seen[$0]++' | paste -sd, -)
    printf '%s\n' "basicConstraints=critical,CA:TRUE" \
        "keyUsage=critical,digitalSignature,keyEncipherment,cRLSign,keyCertSign" \
        "extendedKeyUsage=critical,clientAuth,serverAuth" \
        "subjectAltName=$san_list" >"$TMP/renew.ext"
    chmod 644 "$TMP/renew.ext"
    in_dir "$CERT_DIR" cp -p "$HOST.pem" "$HOST.pem.bak.$(date +%Y%m%d-%H%M%S)"
    in_dir "$CERT_DIR" openssl x509 -x509toreq -in "$HOST.pem" -key "$HOST.key" -out renew.csr 2>/dev/null \
        || die "server certificate renewal failed (request)"
    in_dir "$CERT_DIR" openssl x509 -req -sha256 -in renew.csr -CA ca.pem -CAkey ca.key -CAcreateserial \
        -days "$SRV_DAYS" -extfile "$TMP/renew.ext" -out "$HOST.pem.new" 2>/dev/null \
        || die "server certificate renewal failed (signing)"
    in_dir "$CERT_DIR" mv -f "$HOST.pem.new" "$HOST.pem"
    in_dir "$CERT_DIR" rm -f renew.csr
    # shellcheck disable=SC2016  # $1 is expanded by the inner sh
    in_dir "$CERT_DIR" sh -c 'cat "$1.pem" ca.pem >"$1-chain.pem"' sh "$HOST"
    ok "server certificate renewed for $SRV_DAYS days, same key ($san_list)"
else
    ok "reusing $HOST.pem"
fi
in_dir "$CERT_DIR" sh -c 'chmod 600 ./*.key'
as_goatak test -r "$CERT_DIR/$HOST.key" || die "goatak cannot read $CERT_DIR/$HOST.key"

step "Configuration"
if [[ -f $CONF ]]; then
    root cp -p "$CONF" "$CONF.bak.$(date +%Y%m%d-%H%M%S)"
    ok "backup: $CONF.bak.*"
fi
root install -d -m 755 "$(dirname "$CONF")"
put_file 644 "$CONF" <<EOF
# written by goatak-setup.sh on $(date -Iseconds)

# web GUI / admin API (plain HTTP)
admin_addr: "$ADMIN_ADDR"
# Marti API, mutual TLS (ssl.marti)
api_addr: ":8443"
# certificate enrollment: behind trusted HTTPS Nginx when proxy enabled
cert_addr: "$ENROLL_ADDR"
# unencrypted CoT ("" = disabled)
tcp_addr: $PLAIN_TCP
udp_addr: $PLAIN_UDP
# encrypted CoT for ATAK
tls_addr: ":8089"
local_addr: "localhost:8888"

log: false
data_dir: $STATE/data
webtak_root: ""

me:
  lat: 35.462939
  lon: -97.537283
  zoom: 5

layers:
  - name: OSM
    url: "https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
    max_zoom: 19
    server_parts: ['a', 'b', 'c']
  - name: Opentopo.cz
    url: "https://tile-{s}.opentopomap.cz/{z}/{x}/{y}.png"
    max_zoom: 18
    server_parts: ['a', 'b', 'c']

ssl:
  ca: $CERT_DIR/ca.pem
  cert: $CERT_DIR/$HOST.pem
  key: $CERT_DIR/$HOST.key
  marti: true
  enroll: $([[ $ENROLL_MODE == direct ]] && echo true || echo false)
  cert_ttl_days: 365
EOF
ok "$CONF"

if (( DO_ACCOUNTS )); then
    step "Accounts"
    # temporary instance: admin API on localhost only, no TLS/CoT listeners
    cat >"$TMP/bootstrap.yml" <<EOF
admin_addr: "$BOOT_ADMIN"
api_addr: "$BOOT_API"
local_addr: "$BOOT_LOCAL"
cert_addr: ""
tcp_addr: ""
udp_addr: ""
tls_addr: ""
data_dir: $STATE/data
EOF
    chmod 644 "$TMP/bootstrap.yml"
    in_dir "$STATE" "$BIN" -config "$TMP/bootstrap.yml" >"$TMP/bootstrap.log" 2>&1 &
    BOOT_PID=$!

    for _ in $(seq 60); do
        curl -s -o /dev/null "http://$BOOT_ADMIN/login" && break
        kill -0 "$BOOT_PID" 2>/dev/null || { cat "$TMP/bootstrap.log" >&2; die "bootstrap server exited"; }
        sleep 0.5
    done

    resp=$(curl -s -H 'Content-Type: application/json' \
        --data "{\"login\":\"admin\",\"password\":$(json_str "$CUR_ADMIN_PW")}" "http://$BOOT_ADMIN/token") || true
    TOKEN=$(printf '%s' "$resp" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
    if [[ -z $TOKEN ]]; then
        warn "admin login failed (wrong password?) - account changes skipped"
    else
        # api METHOD PATH JSON -> prints HTTP status
        api() {
            curl -s -o "$TMP/api.out" -w '%{http_code}' -X "$1" \
                -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
                --data "$3" "http://$BOOT_ADMIN$2"
        }

        for i in "${!USERS[@]}"; do
            code=$(api POST /api/device "{\"login\":$(json_str "${USERS[$i]}"),\"password\":$(json_str "${PASSES[$i]}"),\"scope\":$(json_str "${SCOPES[$i]}")}")
            if [[ $code == 200 ]]; then ok "user ${USERS[$i]} created (scope ${SCOPES[$i]})"
            else warn "user ${USERS[$i]}: HTTP $code $(cat "$TMP/api.out")"; fi
        done

        if (( FRESH_DB )); then
            code=$(api PUT /api/device/test '{"scope":"test","disabled":true}')
            if [[ $code == 200 || $code == 404 ]]; then ok "default user 'test' disabled"
            else warn "could not disable 'test' (HTTP $code)"; fi
        fi

        if [[ -n $NEW_ADMIN_PW ]]; then
            code=$(api PUT /api/device/admin "{\"password\":$(json_str "$NEW_ADMIN_PW"),\"scope\":\"admin\",\"disabled\":false}")
            if [[ $code == 200 ]]; then ok "admin password changed"
            else warn "admin password NOT changed (HTTP $code) - change it in the web GUI!"; fi
        fi
    fi

    stop_bootstrap
    wait "$BOOT_PID" 2>/dev/null || true
fi

step "Service ($INIT)"
case $INIT in
systemd)
    put_file 644 /etc/systemd/system/goatak.service <<EOF
[Unit]
Description=GoATAK server
After=network-online.target
Wants=network-online.target

[Service]
User=$SVC_USER
Group=$SVC_USER
WorkingDirectory=$STATE
ExecStart=$BIN -config $CONF
Restart=on-failure
RestartSec=5
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=strict
ReadWritePaths=$STATE

[Install]
WantedBy=multi-user.target
EOF
    root systemctl daemon-reload
    root systemctl enable goatak.service >/dev/null 2>&1
    root systemctl restart goatak.service
    LOGCMD="$ROOT_NAME journalctl -u goatak -n 30 --no-pager"
    ;;
runit)
    root mkdir -p "$SV_DIR/log"
    put_file 755 "$SV_DIR/run" <<EOF
#!/bin/sh
exec 2>&1
cd $STATE || exit 1
exec chpst -u $SVC_USER:$SVC_USER $BIN -config $CONF
EOF
    put_file 755 "$SV_DIR/log/run" <<'EOF'
#!/bin/sh
install -d -m 750 /var/log/goatak
exec svlogd -tt /var/log/goatak
EOF
    if root test -e "$SV_LINK"; then
        root sv restart goatak >/dev/null || true
    else
        root ln -s "$SV_DIR" "$SV_LINK"
    fi
    LOGCMD="$ROOT_NAME tail -n 30 /var/log/goatak/current"
    ;;
none)
    warn "no systemd or runit found - start it yourself:"
    info "cd $STATE && $ROOT_NAME -u $SVC_USER $BIN -config $CONF"
    LOGCMD=""
    ;;
esac

if [[ $INIT != none ]]; then
    for _ in $(seq 30); do
        ss -ltnH 'sport = :8089' | grep -q . && break
        sleep 1
    done
    if ss -ltnH 'sport = :8089' | grep -q .; then
        ok "server is listening on 8089 (TLS)"
    else
        warn "nothing listening on 8089 - check: $LOGCMD"
        $LOGCMD 2>/dev/null | tail -n 15 >&2 || true
    fi
fi

if [[ $ENROLL_MODE != direct ]]; then
    step "Nginx enrollment proxy"
    make_proxy_files
    if [[ $ENROLL_MODE == local ]]; then
        if local_cert_ready; then
            if ask_yn "Install this Nginx site and start/reload Nginx?" y; then
                install_local_site
                if [[ $INIT == systemd ]]; then
                    if root systemctl is-active --quiet nginx; then
                        root systemctl reload nginx || warn "Nginx reload failed; enrollment unavailable until fixed"
                    else
                        root systemctl start nginx || warn "Nginx start failed; enrollment unavailable until fixed"
                    fi
                else
                    warn "Install/start Nginx via your init system; generated config is ready"
                fi
            fi
        else
            warn "GoATAK listens on localhost:8447 but Nginx is not ready. Install trusted certificate and rerun --enrollment-only."
        fi
    else
        warn "Remote Nginx must be installed and old 8446 DNAT removed on the VPS."
        info "FULL VPS RUNBOOK: $PROXY_OUTPUT/REMOTE-NGINX-SETUP.md"
        info "Script does not connect to or alter the VPS. Keep :8089 routing unchanged."
    fi
fi

step "ATAK connection package"
in_dir "$CERT_DIR" cp -f ca.pem ca-trusted.pem
in_dir "$CERT_DIR" rm -f "${HOST}_connect.zip"
in_dir "$CERT_DIR" env SRV_HOST="$HOST" "$TMP/make_connect_dp.sh" >/dev/null 2>&1 \
    || die "data package creation failed"
mkdir -p "$ZIP_DIR"
ZIP="$ZIP_DIR/${HOST}_connect.zip"
# the zip only holds the public CA cert and server address, so it can live in your home
root cat "$CERT_DIR/${HOST}_connect.zip" >"$ZIP"
chmod 644 "$ZIP"
ok "$ZIP"

if (( OPEN_FW )); then
    step "Firewall"
    FW_PORTS=(8089 8443)
    [[ $ENROLL_MODE == remote ]] || FW_PORTS+=(8446)
    for p in "${FW_PORTS[@]}"; do
        case $FW in
            ufw)       root ufw allow "$p/tcp" >/dev/null ;;
            firewalld) root firewall-cmd -q --permanent --add-port="$p/tcp" ;;
        esac
    done
    if [[ $FW == firewalld ]]; then root firewall-cmd -q --reload; fi
    ok "opened ${FW_PORTS[*]}/tcp (not 8447)"
fi

step "Done"
cat <<EOF
    Next steps:
      1. Back up $CERT_DIR/ca.key and ca.pem somewhere off this machine.
      2. Keep WireGuard UDP forwarding unchanged. Make 8089 reachable by TAK clients;
         make 8446 reachable on the Nginx host if using a proxy. Never forward 8447
         on your public router. Expose other API ports only if actually required.
      3. Copy $ZIP to each phone and import it in ATAK
         (menu -> Import). Log in with that person's username and password.
      4. Web GUI: $( [[ $ADMIN_ADDR == 127.* ]] \
            && echo "ssh -L 8088:localhost:8088 <you>@$HOST, then http://localhost:8088" \
            || echo "http://$HOST:8088" )  (user: admin)
      5. Remove someone: disable their account in the web GUI (Devices).
      6. Enrollment HTTPS: $ENROLL_MODE${PROXY_OUTPUT:+; files $PROXY_OUTPUT/README.txt}
${LOGCMD:+    Logs: $LOGCMD}
EOF