# OpenZiti v2 Controller + ZAC + NGINX/Let's Encrypt Deployment Guide

This guide is written for a brand-new Ubuntu VM, for example in Azure, and explains exactly how to run the two deployment scripts in the correct order.

The deployment uses two scripts:

```text
install-openziti-v2-controller-zac.sh
install-nginx-letsencrypt-zac-fix.sh
```

They must be run in this order:

```text
1. install-openziti-v2-controller-zac.sh
2. install-nginx-letsencrypt-zac-fix.sh
```

The first script builds the OpenZiti v2 controller and ZAC.

The second script adds:

```text
NGINX
Let's Encrypt certificate
HTTPS redirect
Reverse proxy to OpenZiti controller
ZAC /assets/ fix for icons, fonts, SVGs, and animations
Certbot auto-renew validation
```

---

## 1. Target Architecture

```text
Browser / Admin
    |
    | https://ziti.example.com/zac/
    |
NGINX on port 443
    |
    | proxy to https://127.0.0.1:1280
    |
OpenZiti Controller + ZAC
```

OpenZiti still uses its own internal PKI for:

```text
Controller identity
Router enrollment
Client identities
Overlay operation
```

Let's Encrypt is only for the browser/admin HTTPS endpoint through NGINX.

---

## 2. Example Values

Replace these values for each customer.

```text
Customer domain: example.com
Controller FQDN: ziti.example.com
Azure DNS label: customer-ziti
Azure DNS name: customer-ziti.<region>.cloudapp.azure.com
Admin email: admin@example.com
OpenZiti admin user: admin
```

Example final URLs:

```text
Direct OpenZiti controller:
https://ziti.example.com:1280/zac/

Browser-trusted NGINX endpoint:
https://ziti.example.com/zac/
```

---

## 3. Create the Azure VM

In Azure Portal, create a new VM.

Recommended VM:

```text
OS: Ubuntu Server 24.04 LTS
Size: Standard B2s or larger
Authentication: SSH key recommended
Public IP: Enabled
Azure DNS label: customer-ziti
```

Azure will create a DNS name similar to:

```text
customer-ziti.<region>.cloudapp.azure.com
```

Example:

```text
customer-ziti.denmarkeast.cloudapp.azure.com
```

---

## 4. Azure NSG Firewall Rules

Open only what is needed.

Before OpenZiti install:

```text
22/tcp      Source: your public admin IP
1280/tcp    Source: your public admin IP or trusted admin network
```

Before running the NGINX/Let's Encrypt script:

```text
80/tcp      Source: Internet
443/tcp     Source: Internet
```

Port `80/tcp` is required for the Let's Encrypt HTTP-01 challenge.

After NGINX works, you may restrict direct `1280/tcp` if browser access is intended to go through NGINX on `443/tcp`.

---

## 5. Configure Public DNS

Create a public DNS record for the controller.

### Option A: CNAME

If your VM has an Azure DNS name:

```text
customer-ziti.<region>.cloudapp.azure.com
```

Create:

```text
Type: CNAME
Name: ziti
Value: customer-ziti.<region>.cloudapp.azure.com
```

This creates:

```text
ziti.example.com
```

### Option B: A Record

Create:

```text
Type: A
Name: ziti
Value: <Azure VM public IP>
```

---

## 6. SSH to the New VM

From your laptop:

```bash
ssh <linux-user>@ziti.example.com
```

Or use the Azure DNS name:

```bash
ssh <linux-user>@customer-ziti.<region>.cloudapp.azure.com
```

Example:

```bash
ssh azureuser@ziti.example.com
```

---

## 7. Update Ubuntu Before Running Any Script

Run this on the VM:

```bash
sudo apt update
sudo apt upgrade -y
sudo reboot
```

Reconnect after reboot:

```bash
ssh <linux-user>@ziti.example.com
```

Install basic tools:

```bash
sudo apt install -y git curl dnsutils jq ca-certificates
```

---

## 8. Verify DNS Before Starting

Run on the VM:

```bash
getent hosts ziti.example.com
```

Check the VM public IP:

```bash
curl -4 https://api.ipify.org
echo
```

The DNS IP and the VM public IP should match.

Example:

```text
getent hosts ziti.example.com
20.30.40.50 ziti.example.com

curl -4 https://api.ipify.org
20.30.40.50
```

If they do not match, stop and fix DNS first.

---

## 9. Get the Scripts onto the VM

You can either clone your repository or upload the scripts manually.

### Option A: Clone GitHub Repository

```bash
git clone https://github.com/<customer-or-org>/<repo>.git
cd <repo>
```

Example:

```bash
git clone https://github.com/example/openziti-deploy.git
cd openziti-deploy
```

### Option B: Upload Scripts Manually

From your laptop:

```bash
scp install-openziti-v2-controller-zac.sh <linux-user>@ziti.example.com:/home/<linux-user>/
scp install-nginx-letsencrypt-zac-fix.sh <linux-user>@ziti.example.com:/home/<linux-user>/
scp README-openziti-v2-controller-nginx-zac.md <linux-user>@ziti.example.com:/home/<linux-user>/
```

Then on the VM:

```bash
cd /home/<linux-user>
```

---

## 10. Make Scripts Executable

Run on the VM:

```bash
chmod +x install-openziti-v2-controller-zac.sh
chmod +x install-nginx-letsencrypt-zac-fix.sh
```

---

# PART A — Install OpenZiti v2 Controller + ZAC

## 11. Run the Controller Script

Run on the controller VM:

```bash
sudo ZITI_DNS='ziti.example.com' \
ZITI_USER='admin' \
ZITI_PWD='StrongPasswordHere' \
./install-openziti-v2-controller-zac.sh
```

Replace:

```text
ziti.example.com
StrongPasswordHere
```

with the real customer values.

---

## 12. Optional Controller Script Variables

### Pin OpenZiti and ZAC versions

```bash
sudo ZITI_DNS='ziti.example.com' \
ZITI_USER='admin' \
ZITI_PWD='StrongPasswordHere' \
OPENZITI_VERSION='2.0.0' \
CONSOLE_VERSION='4.2.0' \
./install-openziti-v2-controller-zac.sh
```

### Let the script run full apt upgrade

Normally, the guide updates Ubuntu before running the script. If you want the script to do it too:

```bash
sudo ZITI_DNS='ziti.example.com' \
ZITI_USER='admin' \
ZITI_PWD='StrongPasswordHere' \
RUN_APT_UPGRADE='true' \
./install-openziti-v2-controller-zac.sh
```

### Skip DNS-to-public-IP match check

Only use this if you know why DNS is not expected to match the VM public IP.

```bash
sudo ZITI_DNS='ziti.example.com' \
ZITI_USER='admin' \
ZITI_PWD='StrongPasswordHere' \
SKIP_DNS_IP_MATCH='true' \
./install-openziti-v2-controller-zac.sh
```

---

## 13. What the Controller Script Does

The controller script:

```text
Validates DNS
Installs required Ubuntu packages
Adds the OpenZiti apt repository
Resolves latest OpenZiti 2.x package versions
Installs:
  openziti
  openziti-controller
  openziti-router
  openziti-console
Bootstraps a new single-node OpenZiti v2 controller
Creates the admin account
Enables ZAC
Creates controller PKI
Creates OpenZiti v2 RAFT database:
  /var/lib/ziti-controller/raft/ctrl-ha.db
Starts ziti-controller.service
Tests local ZAC:
  https://127.0.0.1:1280/zac/
Optionally pins package versions with apt-mark hold
```

---

## 14. Validate the Controller

Run:

```bash
sudo systemctl status ziti-controller.service --no-pager -l
```

Expected:

```text
active (running)
```

Check controller is listening:

```bash
sudo ss -tlnp | grep 1280
```

Expected:

```text
LISTEN ... :1280
```

Check ZAC locally:

```bash
curl -k https://127.0.0.1:1280/zac/ | head
```

Expected:

```html
<!doctype html>
```

Check direct public controller URL:

```bash
curl -k https://ziti.example.com:1280/zac/ | head
```

Expected:

```html
<!doctype html>
```

Login with CLI:

```bash
ziti edge login https://ziti.example.com:1280 -u admin
```

The CLI may ask to trust the OpenZiti controller CA. This is normal.

Then run:

```bash
ziti edge list identities
```

Expected: the default admin identity appears.

---

# PART B — Install NGINX + Let's Encrypt + ZAC Fix

Run this only after PART A succeeds.

## 15. Confirm Azure Ports 80 and 443 Are Open

In Azure NSG, allow:

```text
80/tcp
443/tcp
```

For Let's Encrypt, port `80/tcp` must be reachable from the Internet.

---

## 16. Run the NGINX/Let's Encrypt/ZAC Fix Script

Run on the same controller VM:

```bash
sudo DOMAIN_NAME='ziti.example.com' \
ADMIN_EMAIL='admin@example.com' \
./install-nginx-letsencrypt-zac-fix.sh
```

Replace:

```text
ziti.example.com
admin@example.com
```

with the real customer values.

---

## 17. Optional NGINX Script Variables

### Use Let's Encrypt staging first

This is useful for testing without hitting production rate limits. The certificate will not be browser-trusted.

```bash
sudo DOMAIN_NAME='ziti.example.com' \
ADMIN_EMAIL='admin@example.com' \
CERTBOT_STAGING='true' \
./install-nginx-letsencrypt-zac-fix.sh
```

### Change local controller address or port

Default:

```text
127.0.0.1:1280
```

Override if needed:

```bash
sudo DOMAIN_NAME='ziti.example.com' \
ADMIN_EMAIL='admin@example.com' \
ZITI_CONTROLLER_HOST='127.0.0.1' \
ZITI_CONTROLLER_PORT='1280' \
./install-nginx-letsencrypt-zac-fix.sh
```

### Enable HSTS

Only enable this when you are sure HTTPS will remain permanently available for the domain.

```bash
sudo DOMAIN_NAME='ziti.example.com' \
ADMIN_EMAIL='admin@example.com' \
ENABLE_HSTS='true' \
./install-nginx-letsencrypt-zac-fix.sh
```

---

## 18. What the NGINX Script Does

The NGINX script:

```text
Validates the public domain resolves to this VM
Validates local ZAC is reachable at https://127.0.0.1:1280/zac/
Installs nginx
Installs certbot and python3-certbot-nginx
Requests a Let's Encrypt certificate
Creates HTTP-to-HTTPS redirect
Proxies https://DOMAIN/ to https://127.0.0.1:1280
Adds the ZAC asset fix:
  /assets/ -> /zac/assets/
Tests nginx config
Reloads nginx
Checks certbot timer
Validates these URLs:
  https://DOMAIN/assets/fonts/icomoon.woff2
  https://DOMAIN/assets/animations/Loader.json
  https://DOMAIN/assets/svgs/ziti-logo.svg
```

---

## 19. Why the ZAC `/assets/` Fix Exists

Some ZAC builds request assets from:

```text
/assets/fonts/icomoon.woff2
/assets/fonts/icomoon.ttf
/assets/svgs/ziti-logo.svg
/assets/animations/Loader.json
/assets/images/Icon_Check.png
```

But the OpenZiti controller serves them under:

```text
/zac/assets/fonts/icomoon.woff2
/zac/assets/fonts/icomoon.ttf
/zac/assets/svgs/ziti-logo.svg
/zac/assets/animations/Loader.json
/zac/assets/images/Icon_Check.png
```

Without the NGINX fix, the browser shows 404 errors like:

```text
404 icomoon.woff2
404 ziti-logo.svg
404 Loader.json
Missing icons
Broken logo
Broken animations
Lottie errors
```

The script writes this NGINX block:

```nginx
location /assets/ {
    proxy_pass https://127.0.0.1:1280/zac/assets/;
    proxy_ssl_verify off;
}
```

This makes:

```text
https://ziti.example.com/assets/*
```

map correctly to:

```text
https://127.0.0.1:1280/zac/assets/*
```

---

## 20. Validate Browser HTTPS

Open:

```text
https://ziti.example.com/zac/
```

Expected:

```text
Trusted browser certificate
ZAC login page
Icons visible
Logo visible
No /assets/ 404 errors
```

Hard refresh the browser:

```text
Windows/Linux: Ctrl + Shift + R
macOS: Cmd + Shift + R
```

---

## 21. Validate ZAC Assets from CLI

Run:

```bash
curl -I https://ziti.example.com/assets/fonts/icomoon.woff2
curl -I https://ziti.example.com/assets/animations/Loader.json
curl -I https://ziti.example.com/assets/svgs/ziti-logo.svg
```

Expected:

```text
HTTP/1.1 200 OK
```

---

## 22. Validate NGINX

Run:

```bash
sudo nginx -t
```

Expected:

```text
syntax is ok
test is successful
```

Check service:

```bash
sudo systemctl status nginx --no-pager -l
```

Expected:

```text
active (running)
```

---

## 23. Validate Let's Encrypt Certificate

List certificates:

```bash
sudo certbot certificates
```

Test auto-renewal:

```bash
sudo certbot renew --dry-run
```

Expected:

```text
Congratulations, all simulated renewals succeeded
```

Check renewal timer:

```bash
systemctl list-timers --all | grep certbot
```

---

## 24. Final URLs

Use this for browser/ZAC administration:

```text
https://ziti.example.com/zac/
```

Use this for direct controller/API/CLI access if allowed:

```text
https://ziti.example.com:1280
```

CLI login:

```bash
ziti edge login https://ziti.example.com:1280 -u admin
```

The CLI uses the OpenZiti controller certificate, not the Let's Encrypt certificate. The first CLI login may ask you to trust the OpenZiti CA. That is normal.

---

## 25. Recommended Post-Install Security

After NGINX works:

```text
Keep 22/tcp restricted to your admin IP
Keep 443/tcp open for browser/admin access
Keep 80/tcp open for Let's Encrypt renewal, or ensure HTTP-01 can still work
Restrict 1280/tcp to admin IPs, routers, or trusted networks
Back up /var/lib/ziti-controller
Store admin password securely
```

Back up controller data:

```bash
sudo tar czf openziti-controller-backup-$(date +%F).tgz /var/lib/ziti-controller
```

---

## 26. Rollback NGINX Config

The NGINX script creates timestamped backups:

```text
/etc/nginx/sites-available/default.bak-YYYYMMDDTHHMMSSZ
```

List backups:

```bash
ls -lh /etc/nginx/sites-available/default.bak-*
```

Restore one:

```bash
sudo cp /etc/nginx/sites-available/default.bak-YYYYMMDDTHHMMSSZ /etc/nginx/sites-available/default
sudo nginx -t
sudo systemctl reload nginx
```

---

## 27. Troubleshooting

### DNS does not match VM public IP

Check:

```bash
getent hosts ziti.example.com
curl -4 https://api.ipify.org
```

Fix the public DNS record before continuing.

### Controller script fails because existing state exists

The script is intended for a clean VM.

Existing controller state:

```text
/var/lib/ziti-controller
```

Use a clean VM, or only if you are intentionally destroying the old controller:

```bash
sudo FORCE_CLEAN_INSTALL='true' \
ZITI_DNS='ziti.example.com' \
ZITI_USER='admin' \
ZITI_PWD='StrongPasswordHere' \
./install-openziti-v2-controller-zac.sh
```

### Certbot fails

Check:

```bash
getent hosts ziti.example.com
curl -4 https://api.ipify.org
sudo systemctl status nginx --no-pager -l
```

Also confirm Azure NSG allows:

```text
80/tcp
443/tcp
```

### ZAC icons are missing

Check:

```bash
curl -I https://ziti.example.com/assets/fonts/icomoon.woff2
curl -I https://ziti.example.com/assets/svgs/ziti-logo.svg
curl -I https://ziti.example.com/assets/animations/Loader.json
```

If any return 404, inspect NGINX:

```bash
sudo cat /etc/nginx/sites-available/default
```

Confirm this block exists:

```nginx
location /assets/ {
    proxy_pass https://127.0.0.1:1280/zac/assets/;
    proxy_ssl_verify off;
}
```

### ZAC loads on :1280 but not on 443

Check NGINX:

```bash
sudo nginx -t
sudo systemctl status nginx --no-pager -l
sudo journalctl -u nginx -n 80 --no-pager
```

Check local controller:

```bash
curl -k https://127.0.0.1:1280/zac/ | head
```

### CLI login warns about untrusted certificate

This is normal:

```bash
ziti edge login https://ziti.example.com:1280 -u admin
```

The OpenZiti CLI talks directly to the controller on port `1280`, which uses OpenZiti PKI.

---

## 28. Clean Deployment Checklist

Use this checklist for every customer.

```text
[ ] Azure VM created
[ ] Ubuntu 24.04 LTS selected
[ ] DNS created
[ ] DNS resolves to VM public IP
[ ] Azure NSG allows 22 and 1280
[ ] Ubuntu updated and rebooted
[ ] Scripts copied or repository cloned
[ ] Controller script executed successfully
[ ] ziti-controller.service active
[ ] curl -k https://127.0.0.1:1280/zac/ works
[ ] ziti edge login works
[ ] Azure NSG allows 80 and 443
[ ] NGINX/Let's Encrypt/ZAC fix script executed successfully
[ ] https://DOMAIN/zac/ works
[ ] /assets/fonts/icomoon.woff2 returns 200
[ ] /assets/animations/Loader.json returns 200
[ ] /assets/svgs/ziti-logo.svg returns 200
[ ] sudo certbot renew --dry-run succeeds
[ ] /var/lib/ziti-controller backup created
```

---

## 29. Future Cluster Note

For a future OpenZiti controller cluster, do not rely on one NGINX VM as the only frontend.

Recommended HA design:

```text
ziti.example.com
    |
Azure Load Balancer / Application Gateway
    |
NGINX on each controller node
    |
local OpenZiti controller :1280
```

Each controller node can use the same NGINX script, but cluster advertised addresses and controller bootstrap settings must be planned separately.
