> **EXAMPLE ONLY:** Replace sample host and IP addresses by running `goatak-setup-v2.sh`.

# Remote Nginx for GoATAK Quick Connect — tak.example.com

**Run the installer on the GoATAK desktop, not on the VPS.** The installer
**does not log into or modify the VPS**. It creates this guide and the Nginx
site on the GoATAK desktop, then (only with confirmation) updates GoATAK.

## Your network — write down these three endpoints

| Endpoint | Host/port | Function |
|---|---|---|
| Public enrollment | `tak.example.com:8446` | HTTPS Nginx on VPS; public-trust certificate |
| Backend enrollment | `10.0.0.3:8447` | Plain HTTP on desktop, through private WireGuard/LAN only |
| TAK stream | `tak.example.com:8089` | Existing encrypted GoATAK TCP stream (DO NOT CHANGE) |

Your VPS's **private** WireGuard/LAN source IP: `10.0.0.1`.
GoATAK desktop's **private** WireGuard/LAN IP: `10.0.0.3`.

Phones use **enrollment port 8446** and **stream port 8089**. Never enter 8447
in OmniTAK. Do not expose 8447 on the public internet or copy GoATAK CA
private keys to your VPS.

## Step 1 — On your GoATAK desktop: copy the generated site to the VPS

The file was generated at:

`/tmp/tmp74r_n0c0/goatak-enrollment.conf`

Substitute your VPS SSH user. If SSH is available over WireGuard:

```bash
scp "/tmp/tmp74r_n0c0/goatak-enrollment.conf" VPS_USER@10.0.0.1:/tmp/goatak-enrollment.conf
```

Or copy the file by any secure method. Only the **site configuration** goes
to the VPS; the certificate paths in that file point to files **on the VPS**.

## Step 2 — On your VPS: install the site, verify certificate paths

The VPS must have a publicly trusted full-chain certificate for `tak.example.com`:

```text
Certificate: /etc/letsencrypt/live/tak.example.com/fullchain.pem
Private key: /etc/letsencrypt/live/tak.example.com/privkey.pem
```

Use the existing Let's Encrypt certificate if already installed on the VPS.
The script does **not** issue or renew it. Check the paths in the .conf file.

For Debian/Ubuntu/Arch Nginx using `conf.d/*.conf` **inside `http {}`**:

```bash
sudo nginx -T 2>&1 | grep -E 'include .*conf.d|include .*sites-enabled'
if sudo test -e /etc/nginx/conf.d/goatak-enrollment.conf; then
  sudo cp -a /etc/nginx/conf.d/goatak-enrollment.conf "/etc/nginx/conf.d/goatak-enrollment.conf.bak.$(date +%Y%m%d-%H%M%S)"
fi
sudo install -m 644 /tmp/goatak-enrollment.conf /etc/nginx/conf.d/goatak-enrollment.conf
sudo nginx -t && sudo systemctl reload nginx
sudo ss -lntp | grep ':8446'
```

If your Nginx does NOT include that directory, use the included
`/etc/nginx/sites-enabled` directory or another included `http {}` location.
Do NOT place the site inside a `stream {}` block. Use the VPS's init manager
rather than `systemctl` if different. If `nginx -t` fails, don't reload;
correct the reported problem without touching existing websites.

## Step 3 — On your VPS: remove **old 8446 DNAT**, if applicable

This step is CRITICAL if the VPS previously forwarded public 8446 directly
to GoATAK `10.0.0.3:8446`. The new path is **public 8446 -> VPS Nginx**.
The old DNAT will intercept incoming mobile traffic before Nginx receives it.

Inspect first (read-only):

```bash
sudo iptables -t nat -S | grep -- '--dport 8446' || true
sudo nft list ruleset 2>/dev/null | grep -C 2 'dnat to 10.0.0.3:8446' || true
sudo grep -RIn '8446' /etc/wireguard /etc/iptables /etc/systemd/system 2>/dev/null || true
```

If `/etc/wireguard/wg0.conf` or another WireGuard profile contains a
`PostUp`/`PostDown` command for this **specific** 8446 DNAT, back up
that configuration and remove ONLY that command. Do not remove commands for
8089, other services, or WireGuard itself. If the line contains multiple
semicolon-separated commands, remove only the 8446 command.

If the live firewall uses the **exact** IPv4 iptables rule below, delete all
matching copies **without restarting WireGuard**:

```bash
rule=(-p tcp -m tcp --dport 8446 -j DNAT --to-destination 10.0.0.3:8446)
while sudo iptables -t nat -C PREROUTING "${rule[@]}" 2>/dev/null; do
  sudo iptables -t nat -D PREROUTING "${rule[@]}"
done
```

Do not execute that deletion if your rule differs. Inspect the applicable
chain, nftables rule and persistent firewall manager instead. The deletion
above is for an exact-match iptables PREROUTING rule; it is NOT a general
firewall cleanup tool. `iptables-nft` also shows rules under nftables.

Verify there is no **public 8446 -> 10.0.0.3:8446** DNAT left:

```bash
sudo iptables -t nat -S | grep 8446 || true
sudo nft list ruleset 2>/dev/null | grep -C 2 'dnat to 10.0.0.3:8446' || true
sudo ss -lntp | grep ':8446'
```

Do not restart WireGuard just to apply this change. Make the persistent change
so the DNAT will not return after a reboot. VPS provider/cloud firewalls must
also allow **inbound TCP 8446 to Nginx**. Existing TCP 8089 forwarding remains.

## Step 4 — On the desktop: enable the GoATAK HTTP enrollment backend

Rerun `bash goatak-setup-v2.sh --enrollment-only` (or complete the running
wizard) and select remote Nginx, then confirm the switch once the VPS site
and old DNAT are ready.

The script sets BOTH:

```yaml
cert_addr: "10.0.0.3:8447"
ssl:
  enroll: false
```

`ssl.enroll: false` is ESSENTIAL: the backend behind Nginx speaks **HTTP**,
not HTTPS. Without this, Nginx may return **HTTP 502**. The script preserves
`ssl.marti`, `ssl.ca`, `ssl.cert`, `ssl.key`, account database, CA,
client certificates, and TAK `8089`. It backs up GoATAK configuration before
changing it. A restart briefly interrupts existing clients.

Restrict the desktop's TCP 8447 so **only 10.0.0.1** can reach
`10.0.0.3:8447`, preferably only from the WireGuard interface; do not
WAN-forward 8447. Firewall syntax depends on the desktop's firewall system.

## Step 5 — Verify the WHOLE path, in order

**Run on VPS:** Verify the desktop's backend responds over HTTP:

```bash
curl -sS --max-time 8 -o /dev/null -w 'Backend HTTP: %{http_code}\n'   http://10.0.0.3:8447/Marti/api/tls/config
```

Expected: **any HTTP response** (often 401 without credentials) confirms
connectivity. A status `000` means connection failure. Do not use `-k`.

**Run on VPS:** Verify local Nginx can reach that backend and presents a
trusted certificate:

```bash
curl -sS --max-time 8 --resolve tak.example.com:8446:127.0.0.1   -o /dev/null -w 'Nginx HTTP: %{http_code}\nTLS: %{ssl_verify_result}\n'   https://tak.example.com:8446/Marti/api/tls/config
```

Expected: **TLS 0**, plus an HTTP response such as `401` (unauthenticated
request) or another endpoint response. **HTTP 502** means upstream failure.

**Run on phone using cellular or an independent network:** Open
`https://tak.example.com:8446/` in Safari/Chrome. A 401/404 web response is OK;
timeout/refused/certificate warning is not. Then test OmniTAK Quick Connect
with **enrollment port 8446** and the correct account credentials.

**If local Nginx passes but phones cannot reach it:** inspect old 8446 DNAT,
VPS/cloud INPUT firewall, public IPv4/IPv6 DNS, and traffic with:

```bash
sudo tcpdump -ni any 'tcp port 8446'
```

Remember that Android hotspot sharing may not share a phone's VPN tunnel with
tethered iPads. The public VPS endpoint should not require the phone to join
WireGuard unless your own firewall is configured to restrict it.

## Rollback / troubleshooting

If Nginx returns 502: check `ssl.enroll: false`, GoATAK listener `10.0.0.3:8447`,
Nginx `proxy_pass http://10.0.0.3:8447;`, and desktop firewall.

If Android says **HTTP 401**, the endpoint was reached; check account
credentials only if the **authenticated Quick Connect attempt** gets 401.
A manual `curl` without credentials can normally get 401.

If clients get connection refused: check active DNAT for old 8446, public
firewall and Nginx listening with `ss -lntp`.

To roll back, restore the latest pre-change copy of
`/etc/goatak/goatak_server.yml.bak.*` on the **desktop**, restart GoATAK,
AND restore the previous forwarding path on the VPS if you wish to return to
direct GoATAK 8446. Do not restore outdated port-forward rules unless GoATAK
is once again listening there. Back up current configs before rollback.

**IMPORTANT:** This guide does not run any remote commands. No changes are made
to your VPS until YOU copy and install the config and adjust the forwarding.
