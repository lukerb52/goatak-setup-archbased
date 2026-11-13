# GoATAK AUR setup v2 — remote Nginx + WireGuard enrollment

This revised Bash setup preserves the existing AUR-oriented GoATAK setup and adds a complete **remote VPS / Nginx / WireGuard deployment guide**. It incorporates the real-world fixes required when both iOS and Android OmniTAK were using Quick Connect.

## Quick start (run on GoATAK desktop, not VPS)

```bash
bash goatak-setup-v2.sh --enrollment-only
```

When prompted, choose **remote (`r`)**. Supply:

- **GoATAK private IPv4 reachable by Nginx:** desktop's WireGuard IP, e.g. `10.0.0.3`.
- **Remote Nginx private IPv4:** VPS WireGuard IP, e.g. `10.0.0.1`.
- **TLS cert/key paths:** locations **on the VPS**, usually `/etc/letsencrypt/live/<hostname>/{fullchain,privkey}.pem`.
- **Output directory:** desktop path where the generated Nginx config and guide will be saved.

The wizard generates:

| Generated file | Purpose |
|---|---|
| `goatak-enrollment.conf` | Nginx HTTPS site for enrollment `8446`, proxied to GoATAK HTTP `8447` |
| `REMOTE-NGINX-SETUP.md` | **Detailed numbered VPS setup instructions**, including commands labeled by machine |
| `README.txt` | Short topology overview and references |
| `OPTIONAL-stream-8089.conf` | **Only if** stream `8089` needs Nginx TCP forwarding; leave unused if current forwarding works |

**Follow the generated `REMOTE-NGINX-SETUP.md`.** It is specific to the IP addresses and hostname you entered. The script does **not** connect to, SSH into, or automatically modify the VPS.

## Working topology

```text
Android / iOS OmniTAK
     | HTTPS Quick Connect :8446
     v
VPS Nginx + publicly trusted certificate
     | HTTP via WireGuard to desktop :8447
     v
GoATAK enrollment service (ssl.enroll: false)

Android / iOS OmniTAK
     | encrypted TAK stream :8089
     v
VPS's existing forwarding over WireGuard --> GoATAK :8089
```

### Critical fixes included in v2

1. **`ssl.enroll: false` is applied together with `cert_addr: "<desktop-WG-IP>:8447"`.** The prior script moved the listener without disabling TLS on its internal endpoint, which could yield Nginx **HTTP 502**. Port `8447` is HTTP *only across the private WireGuard path*.
2. **Old `8446` DNAT rule:** guide explicitly tells you to inspect both live iptables/nftables rules *and* persistent WireGuard `PostUp`/`PostDown` entries. Remove ONLY the old public-8446-to-desktop-8446 forwarding. Incoming public TCP `8446` must now terminate at Nginx on the VPS.
3. **Do not disturb `8089`:** the client stream continues to use encrypted TCP port `8089`; your existing forwarding should be left alone.
4. **No premature switchover:** enrollment-only mode generates the guide first; remote changes require explicit confirmation. An already-correct remote GoATAK configuration is detected and left running without another restart.
5. **Stepwise verification:** desktop listener, VPS->desktop HTTP, VPS-local Nginx TLS, public phone connectivity, OmniTAK credentials. A manual unauthenticated `curl` returning **401** is not itself evidence of invalid credentials; authenticated Quick Connect returning 401 can indicate an auth problem.
6. **Rollback reminders:** GoATAK config backups, Nginx config backup guidance, persistent firewall source and no WireGuard restart to apply live rule edits.

## Nginx config location on the VPS

Copy the generated `goatak-enrollment.conf` from the desktop to the VPS, then install it under an **included Nginx `http {}` config directory**, usually:

- `/etc/nginx/conf.d/goatak-enrollment.conf`, if `/etc/nginx/conf.d/*.conf` is included in Nginx's `http {}` block; or
- the relevant `sites-available` / `sites-enabled` paths, if that is how the VPS is organized.

Use `sudo nginx -t` before reload. The generated site listens on TCP `8446`, so an existing website on `443` need not be replaced.

## Existing working installation

**If your current GoATAK, Nginx, and both OmniTAK clients already work, no changes are needed.** Download and save this script for future deployments. Re-running enrollment-only with the same remote settings will regenerate the instructions and skip changing/restarting GoATAK when it detects the correct `cert_addr` and `ssl.enroll` values. It does not automatically change VPS firewall rules.

## Scope / limitations

- Intended for the user's **AUR package layout** (`/usr/bin/goatak_server`, `/etc/goatak/goatak_server.yml`, `/var/lib/goatak`); not a Docker installer.
- Keeps full first-time setup support for **systemd and runit**, but `--full` is **destructive to existing generated GoATAK config and service definitions**; only use for an intentional fresh deployment.
- Remote Nginx can run on **any Linux distro** with a compatible Nginx `http {}` include and a certificate for the chosen hostname.
- Let's Encrypt issuance/renewal, VPS SSH credentials, VPS Nginx installation, persistent firewall management, WireGuard setup and cloud firewall rules are still manual: they vary by provider and topology.
- **Never publicly expose GoATAK's HTTP backend `8447`.** Restrict it to your VPS's private/WireGuard address. Do not disable encrypted TAK streaming `8089`.
- Tested with Bash syntax checks, generated-file inspection, isolated YAML patch tests, and rerun/idempotence tests. **Not executed on your live hosts.**

Reference: [GoATAK's TLS / Nginx setup guide](https://github.com/kdudkov/goatak/wiki/Server-Fast-Start).
