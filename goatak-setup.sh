#!/usr/bin/env bash
#
# goatak-setup.sh - interactive first-time deployment of GoATAK (AUR package `goatak`)
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
# Safe to re-run: existing CA and database are reused, never overwritten.
# Run as root:  sudo bash goatak-setup.sh

set -euo pipefail

# --- fixed paths (match the AUR package) -------------------------------------
BIN=/usr/bin/goatak_server
PKG_CERT=/usr/share/goatak/cert
PKG_DATA=/usr/share/goatak/data
CONF=/etc/goatak/goatak_server.yml
STATE=/var/lib/goatak
SVC_USER=goatak

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

as_goatak() { runuser -u "$SVC_USER" -- "$@"; }

# --- preflight -----------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "run as root (sudo bash $0)"
[[ -x $BIN ]] || die "$BIN not found - install the goatak package first"
[[ -d $PKG_CERT ]] || die "$PKG_CERT not found - is the goatak package installed?"
for cmd in openssl zip curl runuser ss install sed; do
    command -v "$cmd" >/dev/null || die "missing command: $cmd"
done

if ! id "$SVC_USER" >/dev/null 2>&1; then
    if [[ -f /usr/lib/sysusers.d/goatak.conf ]] && command -v systemd-sysusers >/dev/null; then
        systemd-sysusers /usr/lib/sysusers.d/goatak.conf
    else
        useradd -r -d "$STATE" -s /usr/bin/nologin "$SVC_USER"
    fi
    id "$SVC_USER" >/dev/null 2>&1 || die "could not create user $SVC_USER"
fi

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
Press Ctrl+C at any prompt to abort - nothing is changed until you confirm.
EOF

# --- questions -----------------------------------------------------------------
step "Server identity"
while true; do
    ask HOST "Hostname phones will connect to (e.g. tak.example.com)" "$(hostname -f 2>/dev/null || hostname)"
    [[ $HOST =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] && break
    warn "letters, digits, dots and dashes only"
done
ask EXTRA_SANS "Extra names/IPs for the certificate, space separated (optional)" ""
for n in $EXTRA_SANS; do
    [[ $n =~ ^[A-Za-z0-9.:-]+$ ]] || die "invalid name/IP: $n"
done

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

REGEN=1
if [[ -f $CERT_DIR/$HOST.pem && -f $CERT_DIR/$HOST.key ]]; then
    ask_yn "A server certificate for $HOST already exists. Reuse it?" y && REGEN=0
fi

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
[[ -f $STATE/db.sqlite ]] && FRESH_DB=0
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
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    FW=ufw
elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    FW=firewalld
fi
OPEN_FW=0
if [[ $FW != none ]]; then
    step "Firewall"
    ask_yn "Open 8089, 8443 and 8446/tcp in $FW?" y && OPEN_FW=1
fi

# --- summary -------------------------------------------------------------------
step "Summary"
info "hostname:        $HOST ${EXTRA_SANS:+(+ $EXTRA_SANS)}"
info "certificates:    $CERT_DIR ($([[ $REGEN == 1 ]] && echo "new server cert" || echo "reuse server cert"))"
info "config:          $CONF (existing file is backed up)"
info "web GUI:         $ADMIN_ADDR"
info "plain CoT 8999:  $([[ $PLAIN_TCP == '""' ]] && echo disabled || echo enabled)"
info "TLS ports:       8089 (CoT), 8443 (API), 8446 (enrollment)"
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
TMP=$(mktemp -d)
chmod 755 "$TMP"
BOOT_PID=""
cleanup() {
    if [[ -n $BOOT_PID ]]; then
        kill "$BOOT_PID" 2>/dev/null || true
        wait "$BOOT_PID" 2>/dev/null || true
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT

step "Stopping existing service"
case $INIT in
    systemd) systemctl stop goatak.service 2>/dev/null || true ;;
    runit)   [[ -e $SV_LINK ]] && sv down goatak 2>/dev/null || true ;;
esac
ok "done"

step "State directory"
install -d -o "$SVC_USER" -g "$SVC_USER" -m 750 "$STATE"
if [[ ! -d $STATE/data ]]; then
    cp -r "$PKG_DATA" "$STATE/data"
    chown -R "$SVC_USER:$SVC_USER" "$STATE/data"
fi
install -d -o "$SVC_USER" -g "$SVC_USER" -m 750 "$CERT_DIR"
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
chmod 755 "$TMP"/*.sh

cd "$CERT_DIR"
if [[ -f ca.key ]]; then
    ok "CA exists, reusing $CERT_DIR/ca.pem"
    # refresh truststore with the chosen password
    as_goatak openssl pkcs12 -export -nokeys -name ca -in ca.pem -out truststore.p12 -passout "pass:$P12_PASS"
else
    as_goatak "$TMP/make_ca.sh" >/dev/null 2>&1 || die "CA creation failed"
    ok "CA created"
fi

if (( REGEN )); then
    rm -f "$HOST.pem" "$HOST.key"
    # shellcheck disable=SC2086  # EXTRA_SANS is intentionally word-split
    as_goatak "$TMP/make_server_cert.sh" "$HOST" $EXTRA_SANS >/dev/null 2>&1 || die "server certificate creation failed"
    ok "server certificate created for $HOST"
else
    ok "reusing $HOST.pem"
fi
chmod 600 ./*.key
as_goatak test -r "$HOST.key" || die "goatak cannot read $CERT_DIR/$HOST.key"
cd - >/dev/null

step "Configuration"
if [[ -f $CONF ]]; then
    cp -p "$CONF" "$CONF.bak.$(date +%Y%m%d-%H%M%S)"
    ok "backup: $CONF.bak.*"
fi
install -d -m 755 "$(dirname "$CONF")"
cat >"$CONF" <<EOF
# written by goatak-setup.sh on $(date -Iseconds)

# web GUI / admin API (plain HTTP)
admin_addr: "$ADMIN_ADDR"
# Marti API, mutual TLS (ssl.marti)
api_addr: ":8443"
# certificate enrollment, TLS
cert_addr: ":8446"
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
  enroll: true
  cert_ttl_days: 365
EOF
chmod 644 "$CONF"
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
    (cd "$STATE" && exec runuser -u "$SVC_USER" -- "$BIN" -config "$TMP/bootstrap.yml") >"$TMP/bootstrap.log" 2>&1 &
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

        # admin last: the token stays valid, but do it after everything else anyway
        if [[ -n $NEW_ADMIN_PW ]]; then
            code=$(api PUT /api/device/admin "{\"password\":$(json_str "$NEW_ADMIN_PW"),\"scope\":\"admin\",\"disabled\":false}")
            if [[ $code == 200 ]]; then ok "admin password changed"
            else warn "admin password NOT changed (HTTP $code) - change it in the web GUI!"; fi
        fi
    fi

    kill "$BOOT_PID" 2>/dev/null || true
    wait "$BOOT_PID" 2>/dev/null || true
    BOOT_PID=""
fi

step "Service ($INIT)"
case $INIT in
systemd)
    cat >/etc/systemd/system/goatak.service <<EOF
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
    systemctl daemon-reload
    systemctl enable goatak.service >/dev/null 2>&1
    systemctl restart goatak.service
    LOGCMD="journalctl -u goatak -n 30 --no-pager"
    ;;
runit)
    mkdir -p "$SV_DIR/log"
    cat >"$SV_DIR/run" <<EOF
#!/bin/sh
exec 2>&1
cd $STATE || exit 1
exec chpst -u $SVC_USER:$SVC_USER $BIN -config $CONF
EOF
    cat >"$SV_DIR/log/run" <<'EOF'
#!/bin/sh
install -d -m 750 /var/log/goatak
exec svlogd -tt /var/log/goatak
EOF
    chmod 755 "$SV_DIR/run" "$SV_DIR/log/run"
    if [[ -e $SV_LINK ]]; then
        sv restart goatak >/dev/null || true
    else
        ln -s "$SV_DIR" "$SV_LINK"
    fi
    LOGCMD="tail -n 30 /var/log/goatak/current"
    ;;
none)
    warn "no systemd or runit found - start it yourself:"
    info "cd $STATE && runuser -u $SVC_USER -- $BIN -config $CONF"
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

step "ATAK connection package"
cd "$CERT_DIR"
as_goatak cp -f ca.pem ca-trusted.pem
rm -f "${HOST}_connect.zip"
as_goatak env SRV_HOST="$HOST" "$TMP/make_connect_dp.sh" >/dev/null 2>&1 || die "data package creation failed"
ZIP="$CERT_DIR/${HOST}_connect.zip"
ok "$ZIP"
if [[ -n ${SUDO_USER-} && $SUDO_USER != root ]]; then
    home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    if [[ -d $home ]]; then
        install -m 644 -o "$SUDO_USER" "$ZIP" "$home/"
        ok "copied to $home/${HOST}_connect.zip"
        ZIP="$home/${HOST}_connect.zip"
    fi
fi
cd - >/dev/null

if (( OPEN_FW )); then
    step "Firewall"
    for p in 8089 8443 8446; do
        case $FW in
            ufw)       ufw allow "$p/tcp" >/dev/null ;;
            firewalld) firewall-cmd -q --permanent --add-port="$p/tcp" ;;
        esac
    done
    [[ $FW == firewalld ]] && firewall-cmd -q --reload
    ok "opened 8089, 8443, 8446/tcp"
fi

step "Done"
cat <<EOF
    Next steps:
      1. Back up $CERT_DIR/ca.key and ca.pem somewhere off this machine.
      2. If the server is behind NAT, forward TCP 8089, 8443 and 8446 to it.
      3. Copy $ZIP to each phone and import it in ATAK
         (menu -> Import). Log in with that person's username and password.
      4. Web GUI: $( [[ $ADMIN_ADDR == 127.* ]] \
            && echo "ssh -L 8088:localhost:8088 <you>@$HOST, then http://localhost:8088" \
            || echo "http://$HOST:8088" )  (user: admin)
      5. Remove someone: disable their account in the web GUI (Devices).
${LOGCMD:+    Logs: $LOGCMD}
EOF
