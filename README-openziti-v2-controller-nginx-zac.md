# Generic OpenZiti v2 Controller + ZAC + NGINX/Let's Encrypt Deployment

This deployment uses two separate scripts:

```text
install-openziti-v2-controller-zac.sh
install-nginx-letsencrypt-zac-fix.sh
```

They are intentionally separate.

The controller script installs and bootstraps OpenZiti v2.
The NGINX script adds browser-trusted HTTPS, Let's Encrypt auto-renewal, and the ZAC `/assets` reverse-proxy fix.

This avoids breaking the controller installation if DNS, Azure firewall rules, Certbot, or Let's Encrypt are not ready.

---

## Architecture

```text
Browser
  |
  | https://ziti.example.com/zac/
  |
NGINX :443 with Let's Encrypt certificate
  |
  | proxy to https://127.0.0.1:1280
  |
OpenZiti Controller + ZAC
```

The OpenZiti controller keeps using its own OpenZiti PKI for routers, identities, and enrollment.

Let's Encrypt is used only for browser/admin HTTPS through NGINX.

---

## Prerequisites

### 1. Azure VM

Recommended:

```text
Ubuntu 24.04 LTS
Size: Standard B2s or larger
Authentication: SSH key
```

### 2. Azure Network Security Group

Before running the controller script:

```text
22/tcp      your admin IP
1280/tcp    your admin IP or trusted network
```

Before running the NGINX/Let's Encrypt script:

```text
80/tcp      Internet
443/tcp     Internet
```

Port `80/tcp` is required for the Let's Encrypt HTTP-01 challenge.

### 3. Public DNS

Create a DNS record for your customer domain.

Example if Azure public DNS label is:

```text
customer-ziti.region.cloudapp.azure.com
```

Create:

```text
ziti.customer-domain.com CNAME customer-ziti.region.cloudapp.azure.com
```

Or create an `A` record pointing to the Azure public IP.

Verify from the VM:

```bash
getent hosts ziti.customer-domain.com
curl -4 https://api.ipify.org
```

The resolved DNS IP should match the VM public IP.

---

## Script 1: OpenZiti v2 Controller + ZAC

Run on the controller VM.

```bash
chmod +x install-openziti-v2-controller-zac.sh
```

Recommended command:

```bash
sudo ZITI_DNS='ziti.customer-domain.com' \
ZITI_USER='admin' \
ZITI_PWD='StrongPasswordHere' \
./install-openziti-v2-controller-zac.sh
```

Optional version pinning:

```bash
sudo ZITI_DNS='ziti.customer-domain.com' \
ZITI_USER='admin' \
ZITI_PWD='StrongPasswordHere' \
OPENZITI_VERSION='2.0.0' \
CONSOLE_VERSION='4.2.0' \
./install-openziti-v2-controller-zac.sh
```

Optional full Linux upgrade before install:

```bash
sudo ZITI_DNS='ziti.customer-domain.com' \
ZITI_USER='admin' \
ZITI_PWD='StrongPasswordHere' \
RUN_APT_UPGRADE='true' \
./install-openziti-v2-controller-zac.sh
```

### What this script does

It:

```text
Installs OpenZiti apt repository
Installs openziti, openziti-controller, openziti-router, openziti-console
Bootstraps a new single-node OpenZiti v2 controller
Creates the admin account
Enables ZAC
Verifies /var/lib/ziti-controller/raft/ctrl-ha.db
Starts ziti-controller.service
Tests local ZAC at https://127.0.0.1:1280/zac/
Optionally holds package versions
```

### Validate controller

```bash
sudo systemctl status ziti-controller.service --no-pager -l
curl -k https://127.0.0.1:1280/zac/ | head
ziti edge login https://ziti.customer-domain.com:1280 -u admin
ziti edge list identities
```

---

## Script 2: NGINX + Let's Encrypt + ZAC `/assets` Fix

Run only after the controller script succeeds.

```bash
chmod +x install-nginx-letsencrypt-zac-fix.sh
```

Recommended command:

```bash
sudo DOMAIN_NAME='ziti.customer-domain.com' \
ADMIN_EMAIL='admin@customer-domain.com' \
./install-nginx-letsencrypt-zac-fix.sh
```

Optional staging test:

```bash
sudo DOMAIN_NAME='ziti.customer-domain.com' \
ADMIN_EMAIL='admin@customer-domain.com' \
CERTBOT_STAGING='true' \
./install-nginx-letsencrypt-zac-fix.sh
```

### What this script does

It:

```text
Installs nginx
Installs certbot and python3-certbot-nginx
Requests a Let's Encrypt certificate
Enables HTTP to HTTPS redirect
Proxies https://DOMAIN/ to https://127.0.0.1:1280
Adds /assets/ -> /zac/assets/ reverse-proxy fix
Tests nginx config
Reloads nginx
Checks certbot timer
Validates ZAC assets:
  /assets/fonts/icomoon.woff2
  /assets/animations/Loader.json
  /assets/svgs/ziti-logo.svg
```

### Why the `/assets/` fix is needed

Some ZAC versions request static assets from root:

```text
/assets/fonts/icomoon.woff2
/assets/svgs/ziti-logo.svg
/assets/animations/Loader.json
```

But the OpenZiti controller serves these under:

```text
/zac/assets/fonts/icomoon.woff2
/zac/assets/svgs/ziti-logo.svg
/zac/assets/animations/Loader.json
```

Without the NGINX fix, browsers may show:

```text
404 icomoon.woff2
404 ziti-logo.svg
404 Loader.json
Missing icons
Broken animations
Lottie errors
```

The script adds:

```nginx
location /assets/ {
    proxy_pass https://127.0.0.1:1280/zac/assets/;
    proxy_ssl_verify off;
}
```

---

## Validate browser access

Open:

```text
https://ziti.customer-domain.com/zac/
```

Expected:

```text
Trusted browser certificate
ZAC login page
Icons visible
Logo visible
No 404 errors for /assets/*
```

Test from CLI:

```bash
curl -I https://ziti.customer-domain.com/assets/fonts/icomoon.woff2
curl -I https://ziti.customer-domain.com/assets/animations/Loader.json
curl -I https://ziti.customer-domain.com/assets/svgs/ziti-logo.svg
```

Expected:

```text
HTTP/1.1 200 OK
```

---

## Certificate renewal

Certbot installs automatic renewal.

Check timer:

```bash
systemctl list-timers --all | grep certbot
```

Test renewal:

```bash
sudo certbot renew --dry-run
```

List certificate:

```bash
sudo certbot certificates
```

---

## Rollback NGINX

The NGINX script creates timestamped backups:

```text
/etc/nginx/sites-available/default.bak-YYYYMMDDTHHMMSSZ
```

Restore:

```bash
sudo cp /etc/nginx/sites-available/default.bak-YYYYMMDDTHHMMSSZ /etc/nginx/sites-available/default
sudo nginx -t
sudo systemctl reload nginx
```

---

## Recommended deployment order

```text
1. Create Azure VM
2. Configure DNS
3. Open Azure NSG ports 22 and 1280
4. Run install-openziti-v2-controller-zac.sh
5. Verify controller and ZAC on :1280
6. Open Azure NSG ports 80 and 443
7. Run install-nginx-letsencrypt-zac-fix.sh
8. Verify https://DOMAIN/zac/
9. Restrict direct 1280 access if desired
```

---

## Common errors

### DNS resolves to wrong IP

Fix DNS first. The script compares domain DNS to the VM public IP.

### Certbot fails

Check:

```bash
getent hosts ziti.customer-domain.com
curl -4 https://api.ipify.org
sudo systemctl status nginx --no-pager -l
```

Also verify Azure NSG allows `80/tcp`.

### ZAC icons are missing

Check:

```bash
curl -I https://ziti.customer-domain.com/assets/fonts/icomoon.woff2
curl -I https://ziti.customer-domain.com/assets/svgs/ziti-logo.svg
```

If 404, rerun the NGINX script or inspect:

```bash
sudo cat /etc/nginx/sites-available/default
```

### Direct CLI login shows untrusted OpenZiti CA

This is normal for:

```bash
ziti edge login https://ziti.customer-domain.com:1280 -u admin
```

Port 1280 uses OpenZiti controller PKI. Browser-trusted Let's Encrypt is provided through NGINX on 443.

---

## Security notes

For production:

```text
Use a strong admin password
Restrict SSH to your admin IP
Restrict 1280/tcp if NGINX is the admin path
Back up /var/lib/ziti-controller
Keep package versions pinned until you intentionally upgrade
Run certbot dry-run after deployment
```
