# GoATAK AUR setup — iOS Quick Connect / HTTPS enrollment

This is a script that sets up a [GOATAK](https://github.com/kdudkov/goatak) server on arch-based distributions of Linux. It retains the AUR-oriented setup, certificate generation, users, ATAK package export, systemd/runit options and firewall support. It adds the documented split between GoATAK's **encrypted TAK streaming on TCP 8089** and **publicly trusted HTTPS enrollment on TCP 8446**.

**Run this on the GoATAK server, as your regular user (not root):**

```bash
bash goatak-setup-enhanced.sh --enrollment-only
```

On an existing installation, this is the recommended path. It **does not regenerate your CA, TLS stream certificate, client certificates, database or accounts, or overwrite your service unit**. It only writes a focused change to the top-level `cert_addr`, after making a timestamped backup. In local mode it can also install an Nginx configuration. An existing install also defaults to offering this repair when invoked without arguments.

For a new deployment or a complete reconfiguration, use `bash goatak-setup-enhanced.sh --full`. This retains the uploaded script's original full-setup behavior and **can overwrite the generated GoATAK config and service**. Back up your configuration first.

## Choose a proxy layout

| Mode in wizard | GoATAK `cert_addr` | Encrypted TAK | Phone-facing enrollment |
|---|---|---|---|
| Local Nginx | `127.0.0.1:8447` | GoATAK `:8089` unchanged | Nginx `:8446` on GoATAK host |
| Remote Nginx | `<GoATAK-private-IP>:8447` | GoATAK `:8089` unchanged | Nginx `:8446` on second host |
| Direct/legacy | `:8446` (unchanged in repair-only) | GoATAK `:8089` unchanged | GoATAK's private-CA certificate |

Both Nginx options use a **publicly trusted TLS certificate** on the Nginx host, e.g. a Let's Encrypt certificate for the **same hostname OmniTAK uses**. The script asks for the PEM paths *on the Nginx machine* and generates `goatak-enrollment.conf` plus an explanatory `README.txt` at a path you select. It does **not** assume a DNS provider or obtain an ACME certificate automatically; DNS-01 is preferred for WireGuard-only deployments and requires provider-specific credentials/plugins.

### Local Nginx

If Nginx is installed and a verifiable public-trust certificate/key exists, the script offers to install the dedicated config, migrate GoATAK's enrollment backend to localhost `8447`, and start/reload Nginx. The repair path backs up the old configuration and rolls back on service or Nginx start failure. If the prerequisites are missing, the script generates the Nginx config and instructions **without changing the running GoATAK service**.

### Nginx on a different server

Select **remote**, then enter the **GoATAK machine's private WireGuard/LAN IPv4** and the **Nginx machine's private WireGuard/LAN IPv4**. The script generates a portable Nginx site and instructions. Deploy it to the other computer yourself (Arch, Debian, Ubuntu, etc. are possible), obtain its public certificate there, and only then rerun the script to confirm the GoATAK backend change. The remote path **defaults to leaving GoATAK unchanged** until you explicitly confirm the remote proxy is ready.

On the GoATAK host, restrict port `8447` to the remote proxy peer, ideally over a WireGuard interface. The wizard accepts private addresses and CGNAT `100.64.0.0/10` addresses used by some WireGuard-based systems; public and wildcard bind addresses are rejected. If GoATAK binds directly to a VPN interface address, ensure the VPN is up before GoATAK starts (otherwise the service may fail to bind). TCP `8447` is **plain HTTP internally**, so don't expose it to the public internet or transmit enrollment credentials over an untrusted network. Do **not** forward port `8447` on your router.

**Important with two computers:** a single hostname cannot point different TCP ports to different servers through ordinary DNS. Keep the existing hostname and route/forward **8446 to Nginx** while **8089 still reaches GoATAK**. If this is impossible, use TCP pass-through on port `8089` at the Nginx host. For that setup the script also generates `OPTIONAL-stream-8089.conf`, to be installed in Nginx's **`stream {}` context** with the stream module—not in `http {}`. This preserves end-to-end TAK TLS; it does not issue new TAK certificates. Do not enable that optional listener if port 8089 already works.

## Test before retrying OmniTAK

From a machine using its normal public CA store, with no GoATAK private `-CAfile`:

```bash
openssl s_client \
  -connect YOUR_HOSTNAME:8446 \
  -servername YOUR_HOSTNAME \
  -verify_hostname YOUR_HOSTNAME \
  -verify_return_error \
  </dev/null 2>&1 \
  | grep -E 'Verification:|Verify return code:|verify error:'
```

Expected: `Verify return code: 0 (ok)`.

Verify the GoATAK stream still listens on 8089:

```bash
sudo ss -lntp | grep -E ':(8089|8446|8447)\b'
```

Android clients with existing client certificates should continue using `8089` after the short GoATAK service restart. If an iOS client enrolls successfully but still rejects GoATAK's privately signed **stream** certificate, the client may need the GoATAK CA imported through **OmniTAK's own truststore/connection package**. Fixing enrollment TLS does not automatically guarantee the app trusts every streaming certificate.

## Limitations and safety

- The script is designed around the supplied AUR paths (`/usr/bin/goatak_server`, `/etc/goatak/goatak_server.yml`, `/var/lib/goatak`), not Docker. A different package layout may require changing the constants at the top.
- It supports systemd and runit for GoATAK, with local automatic Nginx startup on systemd. On other init systems, use the generated Nginx config with your local service manager.
- It avoids modifying router/WireGuard forwarding automatically because network topologies vary.
- Certificate acquisition and renewal are intentionally not automated: a DNS-01 challenge needs your provider-specific plugin/credentials, and HTTP-01 may require public port 80.
- Nginx must load `/etc/nginx/conf.d/*.conf` in its `http {}` configuration for local automatic installation; otherwise adjust the generated site and Nginx configuration manually.
- Re-run `--enrollment-only` after setting up the certificate and proxy. Always keep copies of the pre-migration config and `ca.key` in secure backups.
- The script has passed Bash syntax checks and isolated tests of its YAML `cert_addr` patch and Nginx file generation, but **has not been executed against a live GoATAK/OmniTAK deployment**.

References: [GoATAK Server Fast Start (TLS and Nginx)](https://github.com/kdudkov/goatak/wiki/Server-Fast-Start), [GoATAK sample config](https://github.com/kdudkov/goatak/blob/master/goatak_server.yml).
