# Stealth DoH v2.1

DNS-over-HTTPS proxy via Cloudflare Worker  
DNSTT / SlipNet integration (6 protocols) + Self-update

---

## فایل‌ها

```
stealth-doh.sh   ← تنها فایل اجرایی
README.md
```

---

## نصب اولیه

```bash
bash stealth-doh.sh install
```

اسکریپت می‌پرسد:
1. IP سرور
2. پسورد پنل ادمین
3. Cloudflare Account ID + API Token + Worker name
4. GitHub URL برای self-update
5. نام اولین کاربر
6. DNSTT سرور (اختیاری)

بعد از نصب، اسکریپت خودش را در `/opt/stealth-doh/stealth-doh.sh` کپی می‌کند  
و دستور `stealth-doh` را در `/usr/local/bin` می‌سازد.

---

## استفاده بعد از نصب

```bash
stealth-doh              # منوی تعاملی
stealth-doh status
stealth-doh add-user
stealth-doh add-dnstt
stealth-doh gen-configs
stealth-doh gen-configs-user
stealth-doh list-templates
stealth-doh test-stub
stealth-doh show-worker
stealth-doh rotate-prefix
stealth-doh deploy-worker
stealth-doh change-password
stealth-doh logs
stealth-doh logs-follow
stealth-doh query-logs
stealth-doh backup
stealth-doh version
stealth-doh update
stealth-doh uninstall
```

---

## پنل گرافیکی

```
https://SERVER_IP/panel
```

بخش‌های پنل:
- **Dashboard** — وضعیت سرویس‌ها، آمار، Worker
- **Users** — افزودن/حذف کاربر، rotate token، نمایش DoH URL + SlipNet configs
- **SlipNet** — مدیریت DNSTT سرور، افزودن templates، generate configs، test stubs
- **Security** — rotate prefix، تغییر پسورد
- **Logs** — query log زنده
- **System** — نسخه، بکاپ، restart

---

## Self-Update

```bash
stealth-doh update     # آپدیت از GitHub
stealth-doh version    # بررسی نسخه
```

فقط `stealth-doh.sh` آپدیت می‌شود.  
**هرگز لمس نمی‌شود:** `.env` ، `db/` ، `unbound.conf` ، `nginx.conf`

---

## GitHub Setup

در فایل `.env` سرور:
```
GITHUB_REPO=https://raw.githubusercontent.com/YOUR_USERNAME/stealth-doh/main
```

هر نسخه جدید: فایل `VERSION` را bump کن.

---

## پروتکل‌های پشتیبانی‌شده

| Protocol | stub-zone |
|---|---|
| Slipstream + SOCKS | ❌ |
| Slipstream + SSH | ❌ |
| DNSTT + SOCKS | ✅ |
| DNSTT + SSH | ✅ |
| NoizDNS + SOCKS | ✅ |
| NoizDNS + SSH | ✅ |

---

## نیازمندی‌ها

- Ubuntu 20.04+ / Debian 11+
- Root access
- Cloudflare account (رایگان)
- Port 443 TCP open
