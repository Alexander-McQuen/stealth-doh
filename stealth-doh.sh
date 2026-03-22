#!/bin/bash
# ╔══════════════════════════════════════════════════════════════╗
# ║  stealth-doh.sh  v2.1  —  Single-file installer + manager   ║
# ╚══════════════════════════════════════════════════════════════╝
# Usage:
#   bash stealth-doh.sh install   — first-time install
#   stealth-doh                   — interactive menu (after install)
#   stealth-doh [command]         — direct command

SCRIPT_VERSION="2.1.0"
GITHUB_RAW="https://raw.githubusercontent.com/YOUR_USERNAME/stealth-doh/main"

BASE="/opt/stealth-doh"
ENV="$BASE/.env"
DB="$BASE/db/stealth.db"
UNBOUND_CONF="/etc/unbound/unbound.conf"
NGINX_CONF="/etc/nginx/conf.d/stealth-doh.conf"
SERVICE_FILE="/etc/systemd/system/stealth-doh.service"
SELF="$BASE/stealth-doh.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "  ${GREEN}✔${NC} $1"; }
warn()    { echo -e "  ${YELLOW}⚠${NC}  $1"; }
err()     { echo -e "  ${RED}✖${NC} $1"; }
section() { echo -e "\n${CYAN}${BOLD}──── $1 ────${NC}"; }

get_env() { grep "^$1=" "$ENV" 2>/dev/null | cut -d= -f2-; }

check_installed() {
    [ -f "$ENV" ] || { err "Not installed. Run: bash stealth-doh.sh install"; exit 1; }
}

# ════════════════════════════════════════════════════
# INSTALL — helper functions
# ════════════════════════════════════════════════════

install_packages() {
    section "Packages"
    apt-get update -qq
    apt-get install -y -qq unbound nginx python3 python3-pip sqlite3 curl wget git ufw 2>/dev/null
    pip3 install -q flask 2>/dev/null
    info "Done."
}

setup_dirs() {
    mkdir -p "$BASE/db" "$BASE/logs" "$BASE/backups"
    chmod 750 "$BASE"
}

setup_db() {
    section "Database"
    sqlite3 "$DB" <<'SQLEOF'
CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL UNIQUE,
    token TEXT NOT NULL UNIQUE,
    query_count INTEGER DEFAULT 0,
    active INTEGER DEFAULT 1,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS logs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts DATETIME DEFAULT CURRENT_TIMESTAMP,
    user_name TEXT, domain TEXT, qtype TEXT, status TEXT, latency_ms INTEGER
);
CREATE TABLE IF NOT EXISTS worker_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    workers_url TEXT NOT NULL,
    active INTEGER DEFAULT 0,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS slipnet_templates (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    proto_type TEXT NOT NULL,
    tunnel_domain TEXT NOT NULL,
    raw_b64 TEXT NOT NULL,
    needs_stub INTEGER DEFAULT 0,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_logs_ts ON logs(ts);
CREATE INDEX IF NOT EXISTS idx_users_token ON users(token);
SQLEOF
    info "DB ready."
}

setup_unbound() {
    section "Unbound"
    cat > "$UNBOUND_CONF" <<'UBEOF'
server:
    verbosity: 0
    interface: 127.0.0.1
    port: 5335
    do-ip4: yes
    do-ip6: no
    do-udp: yes
    do-tcp: yes
    root-hints: "/var/lib/unbound/root.hints"
    auto-trust-anchor-file: "/var/lib/unbound/root.key"
    cache-size: 64m
    cache-min-ttl: 30
    cache-max-ttl: 86400
    num-threads: 2
    msg-cache-size: 16m
    rrset-cache-size: 32m
    hide-identity: yes
    hide-version: yes
    qname-minimisation: yes
    prefetch: yes
    access-control: 127.0.0.0/8 allow
    access-control: 0.0.0.0/0 refuse
UBEOF
    [ ! -f /var/lib/unbound/root.hints ] && \
        curl -sf https://www.internic.net/domain/named.root -o /var/lib/unbound/root.hints 2>/dev/null || true
    unbound-checkconf "$UNBOUND_CONF" &>/dev/null || { err "unbound.conf invalid"; exit 1; }
    systemctl enable unbound --quiet
    systemctl restart unbound
    info "Unbound on 127.0.0.1:5335"
}

setup_nginx() {
    section "Nginx"
    if [ ! -f /etc/ssl/stealth-doh.crt ]; then
        openssl req -x509 -newkey rsa:2048 -nodes \
            -keyout /etc/ssl/stealth-doh.key \
            -out    /etc/ssl/stealth-doh.crt \
            -days 3650 -subj "/CN=${SERVER_IP}" 2>/dev/null
    fi
    cat > "$NGINX_CONF" <<NGEOF
server {
    listen 443 ssl http2;
    server_name _;
    ssl_certificate     /etc/ssl/stealth-doh.crt;
    ssl_certificate_key /etc/ssl/stealth-doh.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305;
    ssl_session_cache   shared:SSL:10m;
    server_tokens off;
    location ~ ^/dns/ {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 10s;
        access_log off;
    }
    location ~ ^/(panel|api)/ {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 30s;
    }
    location /health { proxy_pass http://127.0.0.1:5000; access_log off; }
    location / { return 444; }
}
server { listen 80; server_name _; return 444; }
NGEOF
    nginx -t &>/dev/null && systemctl enable nginx --quiet && systemctl reload nginx
    info "Nginx ready."
}

setup_systemd() {
    section "Service"
    cat > "$SERVICE_FILE" <<SVCEOF
[Unit]
Description=Stealth DoH
After=network.target unbound.service
Requires=unbound.service
[Service]
ExecStart=/usr/bin/python3 $BASE/app.py
WorkingDirectory=$BASE
Restart=always
RestartSec=3
User=root
Environment=PYTHONUNBUFFERED=1
[Install]
WantedBy=multi-user.target
SVCEOF
    systemctl daemon-reload
    systemctl enable stealth-doh --quiet
    systemctl restart stealth-doh
    sleep 2
    systemctl is-active --quiet stealth-doh && info "Service running." || \
        { err "Service failed. Check: journalctl -u stealth-doh -n 20"; exit 1; }
}

setup_deploy_worker_script() {
    cat > "$BASE/deploy_worker.sh" <<'WEOF'
#!/bin/bash
set -e
BASE="/opt/stealth-doh"
get_env() { grep "^$1=" "$BASE/.env" | cut -d= -f2-; }
CF_ACCOUNT_ID=$(get_env CF_ACCOUNT_ID)
CF_API_TOKEN=$(get_env CF_API_TOKEN)
CF_WORKER_NAME=$(get_env CF_WORKER_NAME)
SERVER_IP=$(get_env SERVER_IP)
DOH_PREFIX=$(get_env DOH_PREFIX)
WORKER_JS="const BACKEND='https://${SERVER_IP}';const DOH_PREFIX='${DOH_PREFIX}';
export default{async fetch(request,env){
const url=new URL(request.url);const path=url.pathname;
if(path==='/health')return new Response('OK',{status:200});
const match=path.match(/^\/dns\/([^/]+)\/([^/]+)\$/);
if(!match||match[1]!==DOH_PREFIX)return new Response('Not Found',{status:404});
const backendReq=new Request(BACKEND+path+url.search,{method:request.method,
headers:request.headers,body:request.method==='POST'?request.body:undefined});
try{const r=await fetch(backendReq,{signal:AbortSignal.timeout(10000)});
return new Response(r.body,{status:r.status,headers:{'content-type':r.headers.get('content-type')||'application/dns-message','cache-control':'no-store','access-control-allow-origin':'*'}});}
catch(e){return new Response('Gateway Error',{status:502});}}};"
RESPONSE=$(curl -sf -X PUT \
    "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/workers/scripts/${CF_WORKER_NAME}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/javascript" \
    --data "$WORKER_JS")
if echo "$RESPONSE" | python3 -c "import sys,json;d=json.load(sys.stdin);exit(0 if d.get('success') else 1)" 2>/dev/null; then
    SUB=$(curl -sf "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/workers/subdomain" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" | \
        python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('result',{}).get('subdomain',''))" 2>/dev/null)
    WORKER_URL="https://${CF_WORKER_NAME}.${SUB}.workers.dev"
    sqlite3 "$BASE/db/stealth.db" "UPDATE worker_history SET active=0;"
    sqlite3 "$BASE/db/stealth.db" "INSERT INTO worker_history(workers_url,active) VALUES('$WORKER_URL',1);"
    echo "$WORKER_URL"
else
    echo "FAILED: $RESPONSE"; exit 1
fi
WEOF
    chmod +x "$BASE/deploy_worker.sh"
}

setup_migrate_script() {
    cat > "$BASE/migrate.sh" <<'MEOF'
#!/bin/bash
DB="/opt/stealth-doh/db/stealth.db"
sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS slipnet_templates(id INTEGER PRIMARY KEY AUTOINCREMENT,proto_type TEXT NOT NULL,tunnel_domain TEXT NOT NULL,raw_b64 TEXT NOT NULL,needs_stub INTEGER DEFAULT 0,created_at DATETIME DEFAULT CURRENT_TIMESTAMP);" 2>/dev/null
sqlite3 "$DB" "CREATE INDEX IF NOT EXISTS idx_logs_ts ON logs(ts);" 2>/dev/null
sqlite3 "$DB" "CREATE INDEX IF NOT EXISTS idx_users_token ON users(token);" 2>/dev/null
MEOF
    chmod +x "$BASE/migrate.sh"
}

install_self() {
    cp "$0" "$SELF"
    chmod +x "$SELF"
    ln -sf "$SELF" /usr/local/bin/stealth-doh
    info "stealth-doh command installed."
}

# ════════════════════════════════════════════════════
# INSTALL — main
# ════════════════════════════════════════════════════
cmd_install() {
    [ "$(id -u)" = "0" ] || { err "Must run as root."; exit 1; }
    [ -f "$ENV" ] && { warn "Already installed. Use: stealth-doh update"; exit 0; }

    clear
    echo -e "${CYAN}${BOLD}"
    echo "  ╔═══════════════════════════════════════════════╗"
    echo "  ║  Stealth DoH v${SCRIPT_VERSION} — Install              ║"
    echo "  ╚═══════════════════════════════════════════════╝"
    echo -e "${NC}"

    section "Configuration"
    DEFAULT_IP=$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
    read -rp "  Server IP [$DEFAULT_IP]: " SERVER_IP
    SERVER_IP="${SERVER_IP:-$DEFAULT_IP}"

    while true; do
        read -rsp "  Admin password (min 8 chars): " ADMIN_PASS; echo
        read -rsp "  Repeat: " ADMIN_PASS2; echo
        [ "$ADMIN_PASS" = "$ADMIN_PASS2" ] && [ ${#ADMIN_PASS} -ge 8 ] && break
        err "Mismatch or too short."
    done
    ADMIN_PASS_HASH=$(python3 -c "import hashlib,sys;print(hashlib.sha256(sys.argv[1].encode()).hexdigest())" "$ADMIN_PASS")
    DOH_PREFIX=$(python3 -c "import secrets;print(secrets.token_hex(8))")

    echo ""
    read -rp "  CF Account ID: " CF_ACCOUNT_ID
    read -rp "  CF API Token: " CF_API_TOKEN
    read -rp "  CF Worker name [stealth-doh]: " CF_WORKER_NAME
    CF_WORKER_NAME="${CF_WORKER_NAME:-stealth-doh}"

    echo ""
    read -rp "  GitHub raw URL [$GITHUB_RAW]: " GH_INPUT
    GITHUB_REPO="${GH_INPUT:-$GITHUB_RAW}"

    install_packages
    setup_dirs

    cat > "$ENV" <<EOF
SERVER_IP=${SERVER_IP}
DOH_PREFIX=${DOH_PREFIX}
CF_ACCOUNT_ID=${CF_ACCOUNT_ID}
CF_API_TOKEN=${CF_API_TOKEN}
CF_WORKER_NAME=${CF_WORKER_NAME}
ADMIN_PASS_HASH=${ADMIN_PASS_HASH}
GITHUB_REPO=${GITHUB_REPO}
EOF
    chmod 600 "$ENV"
    info ".env written."

    setup_db
    setup_unbound
    setup_deploy_worker_script
    setup_migrate_script
    install_self

    section "First user"
    read -rp "  First user name [admin]: " FIRST_USER
    FIRST_USER="${FIRST_USER:-admin}"
    TOKEN=$(python3 -c "import secrets;print(secrets.token_hex(16))")
    sqlite3 "$DB" "INSERT INTO users(name,token) VALUES('$FIRST_USER','$TOKEN');"
    echo "$SCRIPT_VERSION" > "$BASE/VERSION"

    # Write app.py then start services
    _write_app
    setup_nginx
    setup_systemd

    # Deploy Worker
    section "Cloudflare Worker"
    WORKER_URL=$(bash "$BASE/deploy_worker.sh" 2>/dev/null) && \
        info "Worker: $WORKER_URL" || warn "Worker deploy failed. Run: stealth-doh deploy-worker"

    # DNSTT (optional)
    _setup_dnstt

    DOH_BASE="${WORKER_URL:-https://${SERVER_IP}}"
    echo ""
    echo -e "${GREEN}${BOLD}═══════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}${BOLD}  ✅ Installed successfully!${NC}"
    echo -e "${GREEN}${BOLD}═══════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  Panel    : ${CYAN}https://${SERVER_IP}/panel${NC}"
    echo -e "  DoH URL  : ${CYAN}${DOH_BASE}/dns/${DOH_PREFIX}/${TOKEN}${NC}"
    echo ""
    echo -e "  Run: ${CYAN}stealth-doh${NC}"
    echo ""
}

# ════════════════════════════════════════════════════
# DNSTT setup helper (called during install)
# ════════════════════════════════════════════════════
_setup_dnstt() {
    echo ""
    echo -e "${CYAN}${BOLD}──── Optional: DNSTT / SlipNet Integration ────${NC}"
    echo ""
    read -rp "  DNSTT server available? (y/N): " HAS
    [ "${HAS,,}" != "y" ] && warn "Skipped. Run later: stealth-doh add-dnstt" && return 0

    read -rp "  DNSTT server IP: " DNSTT_IP
    [ -z "$DNSTT_IP" ] && warn "Skipped." && return 0
    read -rp "  DNSTT DNS port [53]: " DNSTT_PORT
    DNSTT_PORT="${DNSTT_PORT:-53}"
    echo "DNSTT_SERVER_IP=${DNSTT_IP}" >> "$ENV"
    echo "DNSTT_DNS_PORT=${DNSTT_PORT}" >> "$ENV"

    echo ""
    echo -e "  ${YELLOW}Paste slipnet:// URLs (empty line to finish):${NC}"
    _import_slipnet_urls "$DNSTT_IP" "$DNSTT_PORT"
}

_import_slipnet_urls() {
    local DNSTT_IP="$1" DNSTT_PORT="$2"
    local ADDED=0
    local STUB_DOMAINS=()
    while true; do
        read -rp "  slipnet:// URL (Enter to finish): " RAW
        [ -z "$RAW" ] && break
        echo "$RAW" | grep -q "^slipnet://" || { err "Must start with slipnet://"; continue; }
        PARSED=$(python3 - "$RAW" <<'PYEOF'
import base64,sys
url=sys.argv[1].strip()
b64=url[len('slipnet://'):]
b64+='='*(4-len(b64)%4)
try:
    parts=base64.b64decode(b64).decode().split('|')
    if len(parts)<3: print("ERROR:short"); sys.exit(1)
    print(f"{parts[1]}|{parts[2]}")
except Exception as e: print(f"ERROR:{e}"); sys.exit(1)
PYEOF
)
        echo "$PARSED" | grep -q "^ERROR:" && { err "$PARSED"; continue; }
        PROTO=$(echo "$PARSED"|cut -d'|' -f1)
        DOMAIN=$(echo "$PARSED"|cut -d'|' -f2)
        B64=$(echo "$RAW"|sed 's|^slipnet://||')
        case "$PROTO" in dnstt|dnstt_ssh|sayedns|sayedns_ssh) NS=1;; *) NS=0;; esac
        EX=$(sqlite3 "$DB" "SELECT id FROM slipnet_templates WHERE proto_type='$PROTO' AND tunnel_domain='$DOMAIN';" 2>/dev/null)
        if [ -n "$EX" ]; then
            sqlite3 "$DB" "UPDATE slipnet_templates SET raw_b64='$B64',needs_stub=$NS WHERE id=$EX;" 2>/dev/null
            warn "Updated: $PROTO / $DOMAIN"
        else
            sqlite3 "$DB" "INSERT INTO slipnet_templates(proto_type,tunnel_domain,raw_b64,needs_stub) VALUES('$PROTO','$DOMAIN','$B64',$NS);" 2>/dev/null
            info "Saved: $PROTO / $DOMAIN"
        fi
        ADDED=$((ADDED+1))
        [ "$NS" = "1" ] && STUB_DOMAINS+=("$DOMAIN")
    done
    [ ${#STUB_DOMAINS[@]} -gt 0 ] && _add_stub_zones "$DNSTT_IP" "$DNSTT_PORT" "${STUB_DOMAINS[@]}"
    [ $ADDED -gt 0 ] && info "$ADDED template(s) saved." || warn "No templates added."
}

_add_stub_zones() {
    local DNSTT_IP="$1" DNSTT_PORT="$2"; shift 2
    for DOM in "$@"; do
        grep -q "name: \"${DOM}\"" "$UNBOUND_CONF" 2>/dev/null && { warn "stub-zone $DOM exists."; continue; }
        printf '\nstub-zone:\n    name: "%s"\n    stub-addr: %s@%s\n' "$DOM" "$DNSTT_IP" "$DNSTT_PORT" >> "$UNBOUND_CONF"
        info "stub-zone: $DOM → $DNSTT_IP:$DNSTT_PORT"
    done
    if unbound-checkconf "$UNBOUND_CONF" &>/dev/null; then
        systemctl restart unbound && info "Unbound restarted."
    else
        err "unbound.conf error! Fix and restart unbound."
    fi
}

_build_doh_url() {
    local TOKEN="$1"
    local WU PREFIX IP
    WU=$(sqlite3 "$DB" "SELECT workers_url FROM worker_history WHERE active=1 LIMIT 1;" 2>/dev/null)
    PREFIX=$(get_env DOH_PREFIX)
    IP=$(get_env SERVER_IP)
    [ -n "$WU" ] && echo "${WU}/dns/${PREFIX}/${TOKEN}" || echo "https://${IP}/dns/${PREFIX}/${TOKEN}"
}

_process_slipnet_url() {
    python3 - "$1" "$2" <<'PYEOF'
import base64,sys
url=sys.argv[1].strip()
doh=sys.argv[2].strip()
b64=url[len('slipnet://'):]
b64+='='*(4-len(b64)%4)
try:
    decoded=base64.b64decode(b64).decode()
    parts=decoded.split('|')
    if len(parts)<23: print(f"ERROR:fields_{len(parts)}"); sys.exit(1)
    proto=parts[1]; domain=parts[2]
    parts[4]=doh; parts[22]='doh'
    new_b64=base64.b64encode('|'.join(parts).encode()).decode()
    print(f"{proto}|{domain}|slipnet://{new_b64}")
except Exception as e: print(f"ERROR:{e}"); sys.exit(1)
PYEOF
}

# ════════════════════════════════════════════════════
# MANAGE — Service
# ════════════════════════════════════════════════════
cmd_status() {
    check_installed
    echo -e "${BOLD}=== Status ===${NC}"
    for SVC in stealth-doh unbound nginx; do
        systemctl is-active --quiet "$SVC" && \
            echo -e "  $SVC : ${GREEN}● running${NC}" || \
            echo -e "  $SVC : ${RED}● stopped${NC}"
    done
    echo ""
    echo -e "${BOLD}=== Config ===${NC}"
    echo "  Server IP  : $(get_env SERVER_IP)"
    echo "  DoH Prefix : /dns/$(get_env DOH_PREFIX)/"
    echo "  Worker URL : $(sqlite3 "$DB" "SELECT workers_url FROM worker_history WHERE active=1 LIMIT 1;" 2>/dev/null || echo 'Not deployed')"
    echo "  Users      : $(sqlite3 "$DB" "SELECT COUNT(*) FROM users WHERE active=1;" 2>/dev/null)"
    echo "  Queries    : $(sqlite3 "$DB" "SELECT SUM(query_count) FROM users;" 2>/dev/null)"
    echo "  Templates  : $(sqlite3 "$DB" "SELECT COUNT(*) FROM slipnet_templates;" 2>/dev/null)"
    echo "  DNSTT      : $(get_env DNSTT_SERVER_IP || echo 'Not configured')"
    echo "  Panel      : https://$(get_env SERVER_IP)/panel"
    echo "  Version    : $(cat "$BASE/VERSION" 2>/dev/null)"
}

cmd_start()   { check_installed; systemctl start unbound stealth-doh nginx; info "Services started."; }
cmd_stop()    { check_installed; systemctl stop stealth-doh unbound; warn "Services stopped (nginx kept)."; }
cmd_restart() { check_installed; systemctl restart unbound; fuser -k 5000/tcp 2>/dev/null||true; sleep 1; systemctl restart stealth-doh nginx; info "Restarted."; }
cmd_logs()    { check_installed; journalctl -u stealth-doh -n 50 --no-pager; }
cmd_logs_follow() { check_installed; journalctl -u stealth-doh -f; }

cmd_query_logs() {
    check_installed
    echo -e "${BOLD}=== Last 20 DNS Queries ===${NC}"
    printf "%-20s %-12s %-35s %-6s %-5s %s\n" "Time" "User" "Domain" "Type" "Status" "ms"
    echo "──────────────────────────────────────────────────────────────────────"
    sqlite3 "$DB" "SELECT ts,user_name,domain,qtype,status,latency_ms FROM logs ORDER BY id DESC LIMIT 20;" 2>/dev/null | \
    while IFS='|' read -r ts u d qt s ms; do
        printf "%-20s %-12s %-35s %-6s %-5s %s\n" "$ts" "$u" "$d" "$qt" "$s" "${ms}ms"
    done
}

# ════════════════════════════════════════════════════
# MANAGE — Users
# ════════════════════════════════════════════════════
cmd_users() {
    check_installed
    echo -e "${BOLD}=== Users ===${NC}"
    printf "%-4s %-15s %-22s %-8s %s\n" "ID" "Name" "Token (partial)" "Queries" "Status"
    echo "──────────────────────────────────────────────────────────"
    sqlite3 "$DB" "SELECT id,name,token,query_count,active FROM users ORDER BY id;" 2>/dev/null | \
    while IFS='|' read -r id nm tk qc ac; do
        ST=$( [ "$ac" = "1" ] && echo "Active" || echo "Off" )
        printf "%-4s %-15s %-22s %-8s %s\n" "$id" "$nm" "${tk:0:20}..." "$qc" "$ST"
    done
}

cmd_add_user() {
    check_installed
    read -rp "  User name: " NAME
    [ -z "$NAME" ] && err "Name required." && return 1
    TOKEN=$(python3 -c "import secrets;print(secrets.token_hex(16))")
    sqlite3 "$DB" "INSERT INTO users(name,token) VALUES('$NAME','$TOKEN');" 2>/dev/null || \
        { err "User exists."; return 1; }
    DOH_URL=$(_build_doh_url "$TOKEN")
    echo ""
    info "User '$NAME' created."
    echo -e "  DoH URL: ${CYAN}${DOH_URL}${NC}"
    echo ""
    TC=$(sqlite3 "$DB" "SELECT COUNT(*) FROM slipnet_templates;" 2>/dev/null)
    if [ "$TC" -gt 0 ]; then
        echo -e "  ${BOLD}SlipNet configs:${NC}"
        sqlite3 "$DB" "SELECT proto_type,raw_b64 FROM slipnet_templates ORDER BY id;" 2>/dev/null | \
        while IFS='|' read -r PROTO B64; do
            RES=$(_process_slipnet_url "slipnet://${B64}" "$DOH_URL" 2>/dev/null)
            echo "$RES" | grep -q "^ERROR:" || echo "  [${PROTO}] $(echo "$RES"|cut -d'|' -f3)"
        done
    fi
}

cmd_delete_user() {
    check_installed; cmd_users; echo ""
    read -rp "  User ID to delete: " UID
    sqlite3 "$DB" "DELETE FROM users WHERE id='$UID';"
    info "User $UID deleted."
}

cmd_rotate_token() {
    check_installed; cmd_users; echo ""
    read -rp "  User ID: " UID
    NT=$(python3 -c "import secrets;print(secrets.token_hex(16))")
    sqlite3 "$DB" "UPDATE users SET token='$NT' WHERE id='$UID';"
    NM=$(sqlite3 "$DB" "SELECT name FROM users WHERE id='$UID';")
    DOH_URL=$(_build_doh_url "$NT")
    info "Token rotated for '$NM'."
    echo -e "  New DoH URL: ${CYAN}${DOH_URL}${NC}"
    TC=$(sqlite3 "$DB" "SELECT COUNT(*) FROM slipnet_templates;" 2>/dev/null)
    if [ "$TC" -gt 0 ]; then
        echo ""
        sqlite3 "$DB" "SELECT proto_type,raw_b64 FROM slipnet_templates ORDER BY id;" 2>/dev/null | \
        while IFS='|' read -r PROTO B64; do
            RES=$(_process_slipnet_url "slipnet://${B64}" "$DOH_URL" 2>/dev/null)
            echo "$RES" | grep -q "^ERROR:" || echo "  [${PROTO}] $(echo "$RES"|cut -d'|' -f3)"
        done
    fi
}

# ════════════════════════════════════════════════════
# MANAGE — SlipNet / DNSTT
# ════════════════════════════════════════════════════
cmd_add_dnstt() {
    check_installed
    echo -e "${BOLD}=== DNSTT / SlipNet Integration ===${NC}"
    CIP=$(get_env DNSTT_SERVER_IP); CPORT=$(get_env DNSTT_DNS_PORT)
    [ -n "$CIP" ] && echo -e "  Current: ${CYAN}${CIP}:${CPORT:-53}${NC}"
    read -rp "  DNSTT server IP [${CIP}]: " NIP; DNSTT_IP="${NIP:-$CIP}"
    [ -z "$DNSTT_IP" ] && err "IP required." && return 1
    read -rp "  DNS port [${CPORT:-53}]: " NP; DNSTT_PORT="${NP:-${CPORT:-53}}"
    if grep -q "^DNSTT_SERVER_IP=" "$ENV"; then
        sed -i "s|^DNSTT_SERVER_IP=.*|DNSTT_SERVER_IP=${DNSTT_IP}|" "$ENV"
        sed -i "s|^DNSTT_DNS_PORT=.*|DNSTT_DNS_PORT=${DNSTT_PORT}|" "$ENV"
    else
        echo "DNSTT_SERVER_IP=${DNSTT_IP}" >> "$ENV"
        echo "DNSTT_DNS_PORT=${DNSTT_PORT}" >> "$ENV"
    fi
    echo ""
    echo -e "  ${YELLOW}Paste slipnet:// URLs (empty line to finish):${NC}"
    _import_slipnet_urls "$DNSTT_IP" "$DNSTT_PORT"
}

cmd_gen_configs() {
    check_installed
    TC=$(sqlite3 "$DB" "SELECT COUNT(*) FROM slipnet_templates;" 2>/dev/null)
    [ "$TC" -eq 0 ] && err "No templates. Run: stealth-doh add-dnstt" && return 1
    echo -e "${BOLD}=== SlipNet Configs — All Users ===${NC}"
    sqlite3 "$DB" "SELECT name,token FROM users WHERE active=1 ORDER BY id;" 2>/dev/null | \
    while IFS='|' read -r NM TK; do
        DOH_URL=$(_build_doh_url "$TK")
        echo ""
        echo -e "${BOLD}── ${CYAN}${NM}${NC}"
        echo "   DoH: $DOH_URL"
        sqlite3 "$DB" "SELECT proto_type,raw_b64 FROM slipnet_templates ORDER BY id;" 2>/dev/null | \
        while IFS='|' read -r PROTO B64; do
            RES=$(_process_slipnet_url "slipnet://${B64}" "$DOH_URL" 2>/dev/null)
            echo "$RES" | grep -q "^ERROR:" && continue
            echo "   [${PROTO}] $(echo "$RES"|cut -d'|' -f3)"
        done
    done
}

cmd_gen_configs_user() {
    check_installed; cmd_users; echo ""
    read -rp "  User ID: " UID
    IFS='|' read -r NM TK <<< "$(sqlite3 "$DB" "SELECT name,token FROM users WHERE id='$UID' AND active=1;" 2>/dev/null)"
    [ -z "$TK" ] && err "User not found." && return 1
    DOH_URL=$(_build_doh_url "$TK")
    echo ""
    echo -e "${BOLD}=== Configs for: ${CYAN}${NM}${NC} ==="
    echo "  DoH: $DOH_URL"
    echo ""
    sqlite3 "$DB" "SELECT proto_type,raw_b64 FROM slipnet_templates ORDER BY id;" 2>/dev/null | \
    while IFS='|' read -r PROTO B64; do
        RES=$(_process_slipnet_url "slipnet://${B64}" "$DOH_URL" 2>/dev/null)
        echo "$RES" | grep -q "^ERROR:" && continue
        case "$PROTO" in
            ss) LBL="Slipstream+SOCKS";;  slipstream_ssh) LBL="Slipstream+SSH";;
            dnstt) LBL="DNSTT+SOCKS";;    dnstt_ssh) LBL="DNSTT+SSH";;
            sayedns) LBL="NoizDNS+SOCKS";; sayedns_ssh) LBL="NoizDNS+SSH";;
            *) LBL="$PROTO";;
        esac
        echo -e "  ${CYAN}[${LBL}]${NC}"
        echo "  $(echo "$RES"|cut -d'|' -f3)"
        echo ""
    done
}

cmd_list_templates() {
    check_installed
    echo -e "${BOLD}=== Stored Templates ===${NC}"
    printf "%-4s %-18s %-25s %-8s %s\n" "ID" "Protocol" "Domain" "Stub" "Added"
    echo "────────────────────────────────────────────────────────────────"
    sqlite3 "$DB" "SELECT id,proto_type,tunnel_domain,needs_stub,created_at FROM slipnet_templates ORDER BY id;" 2>/dev/null | \
    while IFS='|' read -r id pt td ns ts; do
        SL=$( [ "$ns" = "1" ] && echo "Yes" || echo "No" )
        printf "%-4s %-18s %-25s %-8s %s\n" "$id" "$pt" "$td" "$SL" "$ts"
    done
    DNSTT_IP=$(get_env DNSTT_SERVER_IP)
    [ -n "$DNSTT_IP" ] && echo -e "\n  DNSTT: ${CYAN}${DNSTT_IP}:$(get_env DNSTT_DNS_PORT || echo 53)${NC}" || \
        warn "No DNSTT server. Run: stealth-doh add-dnstt"
}

cmd_test_stub() {
    check_installed
    echo -e "${BOLD}=== Stub-Zone Test ===${NC}"
    sqlite3 "$DB" "SELECT tunnel_domain FROM slipnet_templates WHERE needs_stub=1;" 2>/dev/null | \
    while read -r DOM; do
        echo -n "  $DOM ... "
        R=$(dig @127.0.0.1 -p 5335 "testxyz.${DOM}" TXT +time=3 +tries=1 2>&1)
        echo "$R" | grep -q "flags:.*aa" && echo -e "${GREEN}✅ OK${NC}" || \
            echo -e "${RED}❌ No aa flag — stub-zone not working${NC}"
    done
    echo ""
    echo "  Active stub-zones in unbound.conf:"
    grep -A1 "^stub-zone:" "$UNBOUND_CONF" 2>/dev/null | grep "name:" | sed 's/^/    /'
}

# ════════════════════════════════════════════════════
# MANAGE — Security
# ════════════════════════════════════════════════════
cmd_rotate_prefix() {
    check_installed
    OLD=$(get_env DOH_PREFIX)
    NEW=$(python3 -c "import secrets;print(secrets.token_hex(8))")
    sed -i "s|^DOH_PREFIX=.*|DOH_PREFIX=${NEW}|" "$ENV"
    info "Prefix rotated: $OLD → $NEW"
    echo -e "  ${YELLOW}Redeploying Worker...${NC}"
    WORKER_URL=$(bash "$BASE/deploy_worker.sh" 2>/dev/null) && \
        info "Worker redeployed: $WORKER_URL" || \
        warn "Worker redeploy failed. Run: stealth-doh deploy-worker"
    systemctl restart stealth-doh
    echo ""
    echo -e "${BOLD}Updated URLs:${NC}"
    sqlite3 "$DB" "SELECT name,token FROM users WHERE active=1;" 2>/dev/null | \
    while IFS='|' read -r nm tk; do
        echo -e "  $nm : ${CYAN}$(_build_doh_url "$tk")${NC}"
    done
}

cmd_deploy_worker() {
    check_installed
    echo -e "${YELLOW}Deploying Worker...${NC}"
    WORKER_URL=$(bash "$BASE/deploy_worker.sh" 2>/dev/null) && \
        info "Worker: $WORKER_URL" || err "Deploy failed."
}

cmd_show_worker() {
    check_installed
    WU=$(sqlite3 "$DB" "SELECT workers_url FROM worker_history WHERE active=1 LIMIT 1;" 2>/dev/null)
    echo -e "  Worker URL : ${CYAN}${WU:-Not deployed}${NC}"
    echo -e "  DoH Path   : /dns/$(get_env DOH_PREFIX)/TOKEN"
    echo ""
    echo -e "${BOLD}All DoH URLs:${NC}"
    sqlite3 "$DB" "SELECT name,token FROM users WHERE active=1;" 2>/dev/null | \
    while IFS='|' read -r nm tk; do
        echo -e "  $nm : ${CYAN}$(_build_doh_url "$tk")${NC}"
    done
}

cmd_change_password() {
    check_installed
    while true; do
        read -rsp "  New password (min 8): " P; echo
        read -rsp "  Repeat: " P2; echo
        [ "$P" = "$P2" ] && [ ${#P} -ge 8 ] && break
        err "Mismatch or too short."
    done
    H=$(python3 -c "import hashlib,sys;print(hashlib.sha256(sys.argv[1].encode()).hexdigest())" "$P")
    sed -i "s|^ADMIN_PASS_HASH=.*|ADMIN_PASS_HASH=${H}|" "$ENV"
    systemctl restart stealth-doh
    info "Password changed."
}

# ════════════════════════════════════════════════════
# MANAGE — Maintenance
# ════════════════════════════════════════════════════
cmd_backup() {
    check_installed
    BK="/root/stealth-doh-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
    tar -czf "$BK" "$ENV" "$BASE/db/" "$BASE/VERSION" 2>/dev/null
    info "Backup: $BK"
}

cmd_uninstall() {
    echo -e "${RED}${BOLD}WARNING: Remove everything?${NC}"
    read -rp "Type 'yes': " C
    [ "$C" != "yes" ] && echo "Cancelled." && return 0
    systemctl stop stealth-doh 2>/dev/null; systemctl disable stealth-doh 2>/dev/null
    rm -f "$SERVICE_FILE"; systemctl daemon-reload
    rm -rf "$BASE"
    rm -f "$NGINX_CONF"; systemctl reload nginx 2>/dev/null
    rm -f /usr/local/bin/stealth-doh
    info "Uninstalled."
}

# ════════════════════════════════════════════════════
# MANAGE — Update
# ════════════════════════════════════════════════════
cmd_version() {
    check_installed
    CUR=$(cat "$BASE/VERSION" 2>/dev/null || echo "?")
    GH=$(get_env GITHUB_REPO)
    echo -e "  Installed : ${CYAN}${CUR}${NC}"
    echo -e "  Repo      : ${GH:-Not configured}"
    if [ -n "$GH" ]; then
        echo -n "  Latest    : "
        LATEST=$(curl -sf --max-time 5 "${GH}/VERSION" 2>/dev/null || echo "?")
        if [ "$LATEST" = "$CUR" ]; then echo -e "${GREEN}${LATEST} (up to date)${NC}"
        elif [ "$LATEST" = "?" ]; then echo -e "${YELLOW}Cannot reach GitHub${NC}"
        else echo -e "${YELLOW}${LATEST} (update available → stealth-doh update)${NC}"; fi
    fi
}

cmd_update() {
    check_installed
    GH=$(get_env GITHUB_REPO)
    [ -z "$GH" ] && err "GITHUB_REPO not set in $ENV" && return 1

    CUR=$(cat "$BASE/VERSION" 2>/dev/null || echo "0.0.0")
    echo -n "  Checking latest version ... "
    LATEST=$(curl -sf --max-time 10 "${GH}/VERSION" 2>/dev/null)
    [ -z "$LATEST" ] && err "Cannot reach $GH" && return 1
    echo -e "${GREEN}${LATEST}${NC}"

    if [ "$CUR" = "$LATEST" ]; then
        info "Already up to date ($CUR)."; return 0
    fi

    echo -e "  ${YELLOW}Update: ${CUR} → ${LATEST}${NC}"
    read -rp "  Proceed? (y/N): " C
    [ "${C,,}" != "y" ] && echo "Cancelled." && return 0

    # Backup
    BK="/root/stealth-doh-pre-update-$(date +%Y%m%d-%H%M%S).tar.gz"
    tar -czf "$BK" "$ENV" "$BASE/db/" "$BASE/VERSION" "$SELF" 2>/dev/null
    info "Backup: $BK"

    # Download new script
    echo -n "  Downloading stealth-doh.sh ... "
    if curl -sf --max-time 30 "${GH}/stealth-doh.sh" -o "${SELF}.tmp" && \
       [ -s "${SELF}.tmp" ] && ! grep -q "^<!DOCTYPE" "${SELF}.tmp"; then
        mv "${SELF}.tmp" "$SELF"
        chmod +x "$SELF"
        ln -sf "$SELF" /usr/local/bin/stealth-doh
        echo -e "${GREEN}OK${NC}"
    else
        rm -f "${SELF}.tmp"
        err "Download failed."
        return 1
    fi

    # Run migrations
    echo -n "  Running migrations ... "
    bash "$SELF" _migrate &>/dev/null && echo -e "${GREEN}OK${NC}" || warn "Migration warning."

    # Update VERSION
    echo "$LATEST" > "$BASE/VERSION"

    # Restart
    fuser -k 5000/tcp 2>/dev/null || true; sleep 1
    systemctl restart stealth-doh
    info "Updated: ${CUR} → ${LATEST}"
    echo -e "  ${CYAN}Note: reload this shell or run 'stealth-doh' for new features.${NC}"
}

cmd_migrate() {
    sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS slipnet_templates(id INTEGER PRIMARY KEY AUTOINCREMENT,proto_type TEXT NOT NULL,tunnel_domain TEXT NOT NULL,raw_b64 TEXT NOT NULL,needs_stub INTEGER DEFAULT 0,created_at DATETIME DEFAULT CURRENT_TIMESTAMP);" 2>/dev/null
    sqlite3 "$DB" "CREATE INDEX IF NOT EXISTS idx_logs_ts ON logs(ts);" 2>/dev/null
    sqlite3 "$DB" "CREATE INDEX IF NOT EXISTS idx_users_token ON users(token);" 2>/dev/null
}

# ════════════════════════════════════════════════════
# MANAGE — Help
# ════════════════════════════════════════════════════
cmd_help() {
    echo -e "${BOLD}Service:${NC}"
    echo "  stealth-doh status | start | stop | restart"
    echo "  stealth-doh logs | logs-follow | query-logs"
    echo ""
    echo -e "${BOLD}Users:${NC}"
    echo "  stealth-doh users | add-user | delete-user | rotate-token"
    echo ""
    echo -e "${BOLD}SlipNet/DNSTT:${NC}"
    echo "  stealth-doh add-dnstt          Add/update DNSTT server + templates"
    echo "  stealth-doh gen-configs        Generate URLs for all users"
    echo "  stealth-doh gen-configs-user   Generate URLs for one user"
    echo "  stealth-doh list-templates     Show stored templates"
    echo "  stealth-doh test-stub          Test stub-zones"
    echo ""
    echo -e "${BOLD}Security:${NC}"
    echo "  stealth-doh show-worker        Show Worker URL + all DoH URLs"
    echo "  stealth-doh rotate-prefix      Rotate DoH prefix + redeploy"
    echo "  stealth-doh deploy-worker      Deploy Cloudflare Worker"
    echo "  stealth-doh change-password    Change admin password"
    echo ""
    echo -e "${BOLD}Maintenance:${NC}"
    echo "  stealth-doh backup | uninstall"
    echo "  stealth-doh version | update"
    echo ""
    echo -e "${BOLD}Panel:${NC}"
    echo "  https://SERVER_IP/panel"
}

# ════════════════════════════════════════════════════
# INTERACTIVE MENU
# ════════════════════════════════════════════════════
cmd_menu() {
    while true; do
        clear
        echo -e "${CYAN}${BOLD}"
        echo "  ╔══════════════════════════════════════════════╗"
        echo "  ║        Stealth DoH Manager v$(cat "$BASE/VERSION" 2>/dev/null||echo "?")             ║"
        echo "  ╚══════════════════════════════════════════════╝"
        echo -e "${NC}"

        if [ -f "$ENV" ]; then
            IP=$(get_env SERVER_IP)
            systemctl is-active --quiet stealth-doh && PS="${GREEN}●${NC}" || PS="${RED}●${NC}"
            UC=$(sqlite3 "$DB" "SELECT COUNT(*) FROM users WHERE active=1;" 2>/dev/null||echo 0)
            TC=$(sqlite3 "$DB" "SELECT COUNT(*) FROM slipnet_templates;" 2>/dev/null||echo 0)
            DIP=$(get_env DNSTT_SERVER_IP); [ -z "$DIP" ] && DIP="—"
            echo -e "  ${IP} | Panel: $PS | Users: ${YELLOW}${UC}${NC} | Templates: ${YELLOW}${TC}${NC} | DNSTT: ${CYAN}${DIP}${NC}"
            echo ""
        fi

        echo -e "${BOLD}  ┌── Service ──────────────────────────────────┐${NC}"
        echo -e "  │  ${CYAN}1${NC}  Status                                  │"
        echo -e "  │  ${CYAN}2${NC}  Start / Stop / Restart                  │"
        echo -e "${BOLD}  ├── Users ────────────────────────────────────┤${NC}"
        echo -e "  │  ${CYAN}3${NC}  List users                              │"
        echo -e "  │  ${CYAN}4${NC}  Add user                                │"
        echo -e "  │  ${CYAN}5${NC}  Delete user                             │"
        echo -e "  │  ${CYAN}6${NC}  Rotate token                            │"
        echo -e "${BOLD}  ├── SlipNet / DNSTT ─────────────────────────┤${NC}"
        echo -e "  │  ${CYAN}7${NC}  Add/update DNSTT + templates            │"
        echo -e "  │  ${CYAN}8${NC}  Generate configs — all users            │"
        echo -e "  │  ${CYAN}9${NC}  Generate configs — one user             │"
        echo -e "  │  ${CYAN}10${NC} List templates                          │"
        echo -e "  │  ${CYAN}11${NC} Test stub-zones                         │"
        echo -e "${BOLD}  ├── Security ─────────────────────────────────┤${NC}"
        echo -e "  │  ${CYAN}12${NC} Show all DoH URLs                       │"
        echo -e "  │  ${CYAN}13${NC} Rotate prefix + redeploy                │"
        echo -e "  │  ${CYAN}14${NC} Deploy Worker                           │"
        echo -e "  │  ${CYAN}15${NC} Change password                         │"
        echo -e "${BOLD}  ├── Monitoring ──────────────────────────────┤${NC}"
        echo -e "  │  ${CYAN}16${NC} Logs                                    │"
        echo -e "  │  ${CYAN}17${NC} Live logs                               │"
        echo -e "  │  ${CYAN}18${NC} Query logs                              │"
        echo -e "${BOLD}  ├── Maintenance ─────────────────────────────┤${NC}"
        echo -e "  │  ${CYAN}19${NC} Backup                                  │"
        echo -e "  │  ${CYAN}20${NC} Version                                 │"
        echo -e "  │  ${CYAN}21${NC} Update from GitHub                      │"
        echo -e "  │  ${RED}22${NC} Uninstall                               │"
        echo -e "  │  ${CYAN}0${NC}  Exit                                    │"
        echo -e "${BOLD}  └─────────────────────────────────────────────┘${NC}"
        echo ""
        read -rp "  Enter number: " CH
        echo ""
        case "$CH" in
            1) cmd_status ;;
            2) echo "1=Start 2=Stop 3=Restart"; read -rp "  Choice: " SC
               case "$SC" in 1) cmd_start;; 2) cmd_stop;; 3) cmd_restart;; esac ;;
            3) cmd_users ;;
            4) cmd_add_user ;;
            5) cmd_delete_user ;;
            6) cmd_rotate_token ;;
            7) cmd_add_dnstt ;;
            8) cmd_gen_configs ;;
            9) cmd_gen_configs_user ;;
            10) cmd_list_templates ;;
            11) cmd_test_stub ;;
            12) cmd_show_worker ;;
            13) cmd_rotate_prefix ;;
            14) cmd_deploy_worker ;;
            15) cmd_change_password ;;
            16) cmd_logs ;;
            17) cmd_logs_follow ;;
            18) cmd_query_logs ;;
            19) cmd_backup ;;
            20) cmd_version ;;
            21) cmd_update ;;
            22) cmd_uninstall ;;
            0) exit 0 ;;
            *) err "Invalid." ;;
        esac
        echo ""
        read -rp "  Press Enter to continue..." _
    done
}

# ════════════════════════════════════════════════════
# app.py writer
# ════════════════════════════════════════════════════
_write_app() {
    cat > "$BASE/app.py" <<'PYEOF'
#!/usr/bin/env python3
from flask import Flask,request,Response,redirect,url_for,session,render_template_string,jsonify
import sqlite3,struct,socket,time,hashlib,os,base64,subprocess

app=Flask(__name__)
app.secret_key=os.urandom(32)
BASE='/opt/stealth-doh'
DB=f'{BASE}/db/stealth.db'
ENV=f'{BASE}/.env'

def get_env(k):
    try:
        for l in open(ENV):
            if l.startswith(k+'='): return l.strip().split('=',1)[1]
    except: pass
    return ''

def get_db():
    c=sqlite3.connect(DB); c.row_factory=sqlite3.Row; return c

def resolve_udp(data):
    s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.settimeout(5)
    try: s.sendto(data,('127.0.0.1',5335)); r,_=s.recvfrom(4096); return r
    finally: s.close()

def parse_query(data):
    domain,qtype='?','?'
    try:
        pos,labels=12,[]
        while pos<len(data):
            ln=data[pos]
            if ln==0: pos+=1; break
            labels.append(data[pos+1:pos+1+ln].decode('ascii',errors='replace')); pos+=1+ln
        domain='.'.join(labels)
        if pos+2<=len(data):
            qt=struct.unpack('!H',data[pos:pos+2])[0]
            qtype={1:'A',28:'AAAA',15:'MX',16:'TXT',2:'NS',6:'SOA',5:'CNAME',12:'PTR',33:'SRV',255:'ANY'}.get(qt,str(qt))
    except: pass
    return domain,qtype

def log_query(user_name,data,status,ms):
    try:
        d,qt=parse_query(data); c=get_db()
        c.execute("INSERT INTO logs(ts,user_name,domain,qtype,status,latency_ms) VALUES(datetime('now'),?,?,?,?,?)",(user_name,d,qt,status,ms))
        c.execute("UPDATE users SET query_count=query_count+1 WHERE name=?",(user_name,)); c.commit(); c.close()
    except: pass

@app.route('/dns/<prefix>/<token>',methods=['GET','POST'])
def doh(prefix,token):
    if prefix!=get_env('DOH_PREFIX'): return Response('Not Found',404)
    c=get_db(); u=c.execute("SELECT name FROM users WHERE token=? AND active=1",(token,)).fetchone(); c.close()
    if not u: return Response('Unauthorized',403)
    if request.method=='GET':
        b=request.args.get('dns','')
        if not b: return Response('Bad Request',400)
        b+='='*(-len(b)%4)
        try: query=base64.urlsafe_b64decode(b)
        except: return Response('Bad Request',400)
    else: query=request.data
    if not query: return Response('Bad Request',400)
    t0=time.time()
    try:
        resp=resolve_udp(query); ms=int((time.time()-t0)*1000)
        log_query(u['name'],query,'OK',ms)
        return Response(resp,content_type='application/dns-message')
    except:
        log_query(u['name'],query,'ERR',int((time.time()-t0)*1000))
        return Response('Server Error',500)

# ── Panel auth ────────────────────────────────────
LOGIN="""<!DOCTYPE html><html><head><title>Stealth DoH</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>*{box-sizing:border-box}body{font-family:monospace;background:#0d0d0d;color:#00ff88;
display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0}
.b{background:#151515;border:1px solid #00ff88;border-radius:6px;padding:32px;min-width:320px}
h2{margin:0 0 20px;color:#00ccff}input{background:#0d0d0d;color:#00ff88;border:1px solid #00ff88;
padding:10px;width:100%;margin:6px 0 16px;font-family:monospace;border-radius:3px}
button{background:#00ff88;color:#0d0d0d;border:none;padding:10px;cursor:pointer;
font-family:monospace;font-weight:bold;border-radius:3px;width:100%}
.e{color:#f44;margin-top:8px;font-size:13px}</style></head>
<body><div class="b"><h2>&#x2B21; Stealth DoH</h2>
<form method="post"><input type="password" name="p" placeholder="Password" autofocus>
<button>Login</button></form><div class="e">{{e}}</div></div></body></html>"""

PANEL="""<!DOCTYPE html><html><head><title>Stealth DoH Panel</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
*{box-sizing:border-box}
body{font-family:monospace;background:#0d0d0d;color:#ccc;margin:0}
.sidebar{position:fixed;left:0;top:0;width:200px;height:100vh;background:#111;
border-right:1px solid #222;padding:16px 0;overflow-y:auto}
.sidebar h2{color:#00ccff;padding:0 16px;margin:0 0 16px;font-size:14px}
.nav-item{display:block;padding:10px 16px;color:#aaa;text-decoration:none;cursor:pointer;
font-size:13px;border:none;background:none;width:100%;text-align:left}
.nav-item:hover,.nav-item.active{background:#1a1a1a;color:#00ff88}
.nav-item .icon{margin-right:8px}
.main{margin-left:200px;padding:24px;min-height:100vh}
.header{display:flex;align-items:center;justify-content:space-between;margin-bottom:20px}
.header h1{color:#00ccff;margin:0;font-size:18px}
.stats{display:flex;gap:12px;flex-wrap:wrap;margin-bottom:20px}
.stat{background:#151515;border:1px solid #222;border-radius:6px;padding:12px 20px;text-align:center;min-width:100px}
.stat-n{font-size:24px;font-weight:bold;color:#00ff88}.stat-l{font-size:11px;color:#888}
.card{background:#151515;border:1px solid #222;border-radius:6px;padding:16px;margin-bottom:16px}
.card h3{color:#00ff88;margin:0 0 12px;font-size:14px}
table{width:100%;border-collapse:collapse;font-size:12px}
th,td{border:1px solid #1a1a1a;padding:7px 10px;text-align:left}
th{background:#1a1a1a;color:#00ccff}tr:hover td{background:#1a1a1a}
.url{word-break:break-all;font-size:11px;color:#00ff88;max-width:320px}
.ok{color:#00ff88}.err{color:#f44}.off{color:#666}.warn{color:#fa0}
.btn{background:#1a1a1a;color:#00ccff;border:1px solid #00ccff;padding:5px 12px;
cursor:pointer;font-family:monospace;font-size:12px;border-radius:3px;text-decoration:none}
.btn:hover{background:#00ccff;color:#0d0d0d}
.btn-red{border-color:#f44;color:#f44}.btn-red:hover{background:#f44;color:#0d0d0d}
.btn-green{border-color:#00ff88;color:#00ff88}.btn-green:hover{background:#00ff88;color:#0d0d0d}
.form-row{display:flex;gap:8px;align-items:center;margin-bottom:10px}
.form-row input{background:#0d0d0d;color:#00ff88;border:1px solid #333;padding:7px 10px;
font-family:monospace;font-size:12px;border-radius:3px;flex:1}
.section{display:none}.section.active{display:block}
.badge{padding:2px 8px;border-radius:3px;font-size:11px}
.badge-ok{background:#00ff8820;color:#00ff88}.badge-err{background:#f4444420;color:#f44}
.meta{color:#555;font-size:11px;margin-bottom:16px}
.alert{padding:10px 14px;border-radius:4px;margin-bottom:12px;font-size:13px;display:none}
.alert-ok{background:#00ff8820;border:1px solid #00ff8840;color:#00ff88}
.alert-err{background:#f4444420;border:1px solid #f4444440;color:#f44}
</style></head>
<body>
<div class="sidebar">
  <h2>&#x2B21; Stealth DoH</h2>
  <button class="nav-item active" onclick="show('dashboard')"><span class="icon">◈</span>Dashboard</button>
  <button class="nav-item" onclick="show('users')"><span class="icon">◉</span>Users</button>
  <button class="nav-item" onclick="show('slipnet')"><span class="icon">◎</span>SlipNet</button>
  <button class="nav-item" onclick="show('security')"><span class="icon">◆</span>Security</button>
  <button class="nav-item" onclick="show('logs')"><span class="icon">▤</span>Logs</button>
  <button class="nav-item" onclick="show('system')"><span class="icon">⚙</span>System</button>
  <br><br>
  <a class="nav-item" href="/panel/logout">&#x23CF; Logout</a>
</div>

<div class="main">
  <div id="flash" class="alert"></div>

  <!-- Dashboard -->
  <div class="section active" id="sec-dashboard">
    <div class="header"><h1>Dashboard</h1>
      <span class="meta">v{{ver}} | {{ip}}</span>
    </div>
    <div class="stats">
      <div class="stat"><div class="stat-n" id="s-users">{{uc}}</div><div class="stat-l">Users</div></div>
      <div class="stat"><div class="stat-n" id="s-queries">{{tq}}</div><div class="stat-l">Queries</div></div>
      <div class="stat"><div class="stat-n">{{tc}}</div><div class="stat-l">Templates</div></div>
      <div class="stat"><div class="stat-n" id="s-svc" class="{{svc_color}}">{{svc_status}}</div><div class="stat-l">Services</div></div>
    </div>
    <div class="card">
      <h3>Service Status</h3>
      {% for s,ok in services %}<div style="padding:4px 0">
        <span class="{{'ok' if ok else 'err'}}">{{ '●' if ok else '○' }}</span>
        <span style="margin-left:8px">{{s}}</span>
      </div>{% endfor %}
    </div>
    <div class="card">
      <h3>Worker</h3>
      <p class="meta">{{wu or 'Not deployed'}}</p>
      <a class="btn" onclick="apiAction('/api/deploy-worker','POST')">⟳ Redeploy</a>
    </div>
  </div>

  <!-- Users -->
  <div class="section" id="sec-users">
    <div class="header"><h1>Users</h1></div>
    <div class="card">
      <h3>Add User</h3>
      <div class="form-row">
        <input id="new-user-name" placeholder="Username">
        <button class="btn btn-green" onclick="addUser()">+ Add</button>
      </div>
    </div>
    <div class="card">
      <h3>Users</h3>
      <table><tr><th>ID</th><th>Name</th><th>DoH URL</th><th>Queries</th><th>Status</th><th>Actions</th></tr>
      {% for u in users %}
      <tr>
        <td>{{u.id}}</td><td>{{u.name}}</td>
        <td class="url">{{u.doh_url}}</td>
        <td>{{u.qc}}</td>
        <td><span class="badge {{'badge-ok' if u.active else ''}}">{{ 'Active' if u.active else 'Off' }}</span></td>
        <td>
          <a class="btn" onclick="rotateToken({{u.id}}, '{{u.name}}')">↻ Token</a>
          <a class="btn btn-red" onclick="deleteUser({{u.id}}, '{{u.name}}')">✕</a>
        </td>
      </tr>
      {% endfor %}</table>
    </div>
    <div class="card" id="slipnet-configs-box" style="display:none">
      <h3>SlipNet Configs</h3>
      <div id="slipnet-configs-content"></div>
    </div>
  </div>

  <!-- SlipNet -->
  <div class="section" id="sec-slipnet">
    <div class="header"><h1>SlipNet / DNSTT</h1></div>
    <div class="card">
      <h3>DNSTT Server</h3>
      <div class="form-row">
        <input id="dnstt-ip" placeholder="Server IP" value="{{dnstt_ip}}">
        <input id="dnstt-port" placeholder="DNS Port" value="{{dnstt_port or 53}}" style="max-width:80px">
        <button class="btn btn-green" onclick="saveDnstt()">Save</button>
      </div>
    </div>
    <div class="card">
      <h3>Add slipnet:// Template</h3>
      <div class="form-row">
        <input id="slipnet-url" placeholder="slipnet://...">
        <button class="btn btn-green" onclick="addTemplate()">+ Add</button>
      </div>
    </div>
    <div class="card">
      <h3>Stored Templates</h3>
      <table><tr><th>ID</th><th>Protocol</th><th>Domain</th><th>Stub-zone</th><th>Actions</th></tr>
      {% for t in templates %}
      <tr>
        <td>{{t.id}}</td><td>{{t.proto_type}}</td><td>{{t.tunnel_domain}}</td>
        <td><span class="{{'ok' if t.needs_stub else 'off'}}">{{ '✅' if t.needs_stub else '—' }}</span></td>
        <td><a class="btn btn-red" onclick="deleteTemplate({{t.id}})">✕</a></td>
      </tr>{% endfor %}</table>
    </div>
    <div class="card">
      <h3>Generate Configs</h3>
      <div class="form-row">
        <select id="gen-user-id" style="background:#0d0d0d;color:#00ff88;border:1px solid #333;padding:7px;font-family:monospace;border-radius:3px">
          <option value="all">All users</option>
          {% for u in users %}<option value="{{u.id}}">{{u.name}}</option>{% endfor %}
        </select>
        <button class="btn btn-green" onclick="genConfigs()">Generate</button>
        <button class="btn" onclick="testStub()">Test Stubs</button>
      </div>
      <pre id="gen-output" style="background:#0d0d0d;padding:12px;border-radius:4px;font-size:11px;color:#00ff88;white-space:pre-wrap;display:none"></pre>
    </div>
  </div>

  <!-- Security -->
  <div class="section" id="sec-security">
    <div class="header"><h1>Security</h1></div>
    <div class="card">
      <h3>DoH Prefix (Moving Target)</h3>
      <p class="meta">Current: /dns/{{prefix}}/</p>
      <button class="btn warn" onclick="if(confirm('Rotate prefix and redeploy Worker?')) apiAction('/api/rotate-prefix','POST')">
        ↻ Rotate Prefix + Redeploy
      </button>
    </div>
    <div class="card">
      <h3>Change Admin Password</h3>
      <div class="form-row">
        <input type="password" id="new-pass" placeholder="New password (min 8)">
        <input type="password" id="new-pass2" placeholder="Repeat">
        <button class="btn btn-green" onclick="changePass()">Change</button>
      </div>
    </div>
  </div>

  <!-- Logs -->
  <div class="section" id="sec-logs">
    <div class="header"><h1>Query Logs</h1>
      <button class="btn" onclick="refreshLogs()">↻ Refresh</button>
    </div>
    <div class="card">
      <table id="logs-table">
        <tr><th>Time</th><th>User</th><th>Domain</th><th>Type</th><th>Status</th><th>ms</th></tr>
        {% for l in logs %}
        <tr>
          <td>{{l.ts}}</td><td>{{l.user_name}}</td><td>{{l.domain}}</td>
          <td>{{l.qtype}}</td>
          <td><span class="{{'ok' if l.status=='OK' else 'err'}}">{{l.status}}</span></td>
          <td>{{l.latency_ms}}</td>
        </tr>{% endfor %}
      </table>
    </div>
  </div>

  <!-- System -->
  <div class="section" id="sec-system">
    <div class="header"><h1>System</h1></div>
    <div class="card">
      <h3>Version</h3>
      <p class="meta">Installed: v{{ver}}</p>
      <button class="btn" onclick="checkUpdate()">Check for Updates</button>
      <pre id="update-output" style="background:#0d0d0d;padding:12px;border-radius:4px;font-size:11px;color:#ccc;white-space:pre-wrap;display:none;margin-top:8px"></pre>
    </div>
    <div class="card">
      <h3>Backup</h3>
      <button class="btn btn-green" onclick="apiAction('/api/backup','POST')">⬇ Create Backup</button>
    </div>
    <div class="card">
      <h3>Services</h3>
      <button class="btn" onclick="apiAction('/api/restart','POST')">↻ Restart All</button>
    </div>
  </div>
</div>

<script>
function show(sec){
  document.querySelectorAll('.section').forEach(s=>s.classList.remove('active'));
  document.querySelectorAll('.nav-item').forEach(b=>b.classList.remove('active'));
  document.getElementById('sec-'+sec).classList.add('active');
  event.target.closest('.nav-item').classList.add('active');
}
function flash(msg,ok){
  const el=document.getElementById('flash');
  el.className='alert '+(ok?'alert-ok':'alert-err');
  el.textContent=msg; el.style.display='block';
  setTimeout(()=>el.style.display='none',4000);
}
async function api(url,method='GET',body=null){
  const opts={method,headers:{'Content-Type':'application/json'}};
  if(body) opts.body=JSON.stringify(body);
  const r=await fetch(url,opts);
  return r.json();
}
async function apiAction(url,method,body=null,msg='Done.'){
  const r=await api(url,method,body);
  flash(r.message||msg, r.ok);
  if(r.ok) setTimeout(()=>location.reload(),1200);
}
async function addUser(){
  const nm=document.getElementById('new-user-name').value.trim();
  if(!nm){flash('Name required.',false);return;}
  const r=await api('/api/users','POST',{name:nm});
  if(r.ok){
    flash('User created!',true);
    if(r.slipnet_configs && r.slipnet_configs.length>0){
      const box=document.getElementById('slipnet-configs-box');
      const content=document.getElementById('slipnet-configs-content');
      content.innerHTML='<p style="color:#888;font-size:12px">DoH URL: '+r.doh_url+'</p>'+
        r.slipnet_configs.map(c=>'<div style="margin:4px 0"><span style="color:#fa0">['+c.proto+']</span><br><span style="font-size:11px;color:#00ff88;word-break:break-all">'+c.url+'</span></div>').join('');
      box.style.display='block';
    }
    setTimeout(()=>location.reload(),2000);
  } else flash(r.message||'Error',false);
}
async function deleteUser(id,nm){
  if(!confirm('Delete user '+nm+'?')) return;
  apiAction('/api/users/'+id,'DELETE','','Deleted.');
}
async function rotateToken(id,nm){
  if(!confirm('Rotate token for '+nm+'? Old DoH URL will stop working.')) return;
  const r=await api('/api/users/'+id+'/rotate','POST');
  if(r.ok){
    flash('Token rotated. New DoH URL: '+r.doh_url,true);
    setTimeout(()=>location.reload(),2000);
  } else flash(r.message||'Error',false);
}
async function saveDnstt(){
  const ip=document.getElementById('dnstt-ip').value.trim();
  const port=document.getElementById('dnstt-port').value.trim()||'53';
  if(!ip){flash('IP required.',false);return;}
  apiAction('/api/dnstt','POST',{ip,port});
}
async function addTemplate(){
  const url=document.getElementById('slipnet-url').value.trim();
  if(!url.startsWith('slipnet://')){flash('Must start with slipnet://',false);return;}
  apiAction('/api/templates','POST',{url});
}
async function deleteTemplate(id){
  if(!confirm('Delete template '+id+'?')) return;
  apiAction('/api/templates/'+id,'DELETE');
}
async function genConfigs(){
  const uid=document.getElementById('gen-user-id').value;
  const url=uid==='all'?'/api/gen-configs':'/api/gen-configs/'+uid;
  const r=await api(url);
  const out=document.getElementById('gen-output');
  out.style.display='block';
  out.textContent=r.output||r.message;
}
async function testStub(){
  const r=await api('/api/test-stub');
  const out=document.getElementById('gen-output');
  out.style.display='block';
  out.textContent=r.output||r.message;
}
async function changePass(){
  const p=document.getElementById('new-pass').value;
  const p2=document.getElementById('new-pass2').value;
  if(p!==p2){flash('Passwords do not match.',false);return;}
  if(p.length<8){flash('Too short.',false);return;}
  apiAction('/api/change-password','POST',{password:p});
}
async function checkUpdate(){
  const out=document.getElementById('update-output');
  out.style.display='block'; out.textContent='Checking...';
  const r=await api('/api/version');
  out.textContent=r.output||r.message;
}
async function refreshLogs(){
  const r=await api('/api/query-logs');
  if(r.logs){
    const t=document.getElementById('logs-table');
    const header=t.rows[0].outerHTML;
    t.innerHTML=header+r.logs.map(l=>`<tr><td>${l.ts}</td><td>${l.user_name}</td><td>${l.domain}</td><td>${l.qtype}</td><td>${l.status}</td><td>${l.latency_ms}</td></tr>`).join('');
  }
}
</script>
</body></html>"""

@app.route('/panel',methods=['GET','POST'])
def panel():
    if request.method=='POST':
        ph=hashlib.sha256(request.form.get('p','').encode()).hexdigest()
        if ph==get_env('ADMIN_PASS_HASH'):
            session['admin']=True; return redirect(url_for('panel'))
        return render_template_string(LOGIN,e='Invalid password')
    if not session.get('admin'):
        return render_template_string(LOGIN,e='')
    return render_template_string(PANEL,**_panel_data())

def _panel_data():
    c=get_db()
    ur=c.execute("SELECT id,name,token,query_count,active FROM users ORDER BY id").fetchall()
    lr=c.execute("SELECT ts,user_name,domain,qtype,status,latency_ms FROM logs ORDER BY id DESC LIMIT 50").fetchall()
    wr=c.execute("SELECT workers_url FROM worker_history WHERE active=1 LIMIT 1").fetchone()
    tq=c.execute("SELECT SUM(query_count) FROM users").fetchone()[0] or 0
    has_t=c.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='slipnet_templates'").fetchone()
    tc=c.execute("SELECT COUNT(*) FROM slipnet_templates").fetchone()[0] if has_t else 0
    tr=c.execute("SELECT id,proto_type,tunnel_domain,needs_stub FROM slipnet_templates ORDER BY id").fetchall() if has_t else []
    c.close()
    pref=get_env('DOH_PREFIX'); ip=get_env('SERVER_IP')
    wu=wr['workers_url'] if wr else ''
    ver=open(f'{BASE}/VERSION').read().strip() if os.path.exists(f'{BASE}/VERSION') else '?'
    dnstt_ip=get_env('DNSTT_SERVER_IP'); dnstt_port=get_env('DNSTT_DNS_PORT')
    import subprocess as sp
    services=[(s, sp.run(['systemctl','is-active',s],capture_output=True).returncode==0)
               for s in ['stealth-doh','unbound','nginx']]
    all_ok=all(ok for _,ok in services)
    class U: pass
    users=[]
    for r in ur:
        u=U(); u.id=r['id']; u.name=r['name']; u.qc=r['query_count']; u.active=r['active']
        base=wu if wu else f"https://{ip}"
        u.doh_url=f"{base}/dns/{pref}/{r['token']}"
        users.append(u)
    return dict(users=users,logs=lr,uc=len(users),tq=tq,tc=tc,
                templates=tr,ip=ip,wu=wu,ver=ver,prefix=pref,
                dnstt_ip=dnstt_ip,dnstt_port=dnstt_port,
                services=services,svc_status='OK' if all_ok else 'WARN',
                svc_color='ok' if all_ok else 'warn')

# ── REST API ──────────────────────────────────────
def require_admin(f):
    from functools import wraps
    @wraps(f)
    def decorated(*a,**kw):
        if not session.get('admin'): return jsonify({'ok':False,'message':'Unauthorized'}),403
        return f(*a,**kw)
    return decorated

def _build_doh_url(token):
    c=get_db()
    wr=c.execute("SELECT workers_url FROM worker_history WHERE active=1 LIMIT 1").fetchone()
    c.close()
    wu=wr['workers_url'] if wr else ''
    ip=get_env('SERVER_IP'); pref=get_env('DOH_PREFIX')
    base=wu if wu else f"https://{ip}"
    return f"{base}/dns/{pref}/{token}"

def _process_slipnet(url,doh):
    try:
        b64=url[len('slipnet://'):]
        b64+='='*(-len(b64)%4)
        decoded=base64.b64decode(b64).decode()
        parts=decoded.split('|')
        if len(parts)<23: return None,None,None
        proto=parts[1]; domain=parts[2]
        parts[4]=doh; parts[22]='doh'
        new_b64=base64.b64encode('|'.join(parts).encode()).decode()
        return proto,domain,f"slipnet://{new_b64}"
    except: return None,None,None

@app.route('/api/users',methods=['GET','POST'])
@require_admin
def api_users():
    if request.method=='GET':
        c=get_db()
        users=c.execute("SELECT id,name,token,query_count,active FROM users ORDER BY id").fetchall()
        c.close()
        return jsonify({'ok':True,'users':[dict(u) for u in users]})
    data=request.json or {}
    name=data.get('name','').strip()
    if not name: return jsonify({'ok':False,'message':'Name required'})
    import secrets as sec
    token=sec.token_hex(16)
    try:
        c=get_db(); c.execute("INSERT INTO users(name,token) VALUES(?,?)",(name,token)); c.commit(); c.close()
    except: return jsonify({'ok':False,'message':'User already exists'})
    doh_url=_build_doh_url(token)
    # Generate slipnet configs if templates exist
    c=get_db()
    has_t=c.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='slipnet_templates'").fetchone()
    templates=c.execute("SELECT proto_type,raw_b64 FROM slipnet_templates ORDER BY id").fetchall() if has_t else []
    c.close()
    configs=[]
    for t in templates:
        proto,domain,new_url=_process_slipnet(f"slipnet://{t['raw_b64']}",doh_url)
        if new_url: configs.append({'proto':t['proto_type'],'url':new_url})
    return jsonify({'ok':True,'message':f"User '{name}' created",'doh_url':doh_url,'slipnet_configs':configs})

@app.route('/api/users/<int:uid>',methods=['DELETE'])
@require_admin
def api_delete_user(uid):
    c=get_db(); c.execute("DELETE FROM users WHERE id=?",(uid,)); c.commit(); c.close()
    return jsonify({'ok':True,'message':'User deleted'})

@app.route('/api/users/<int:uid>/rotate',methods=['POST'])
@require_admin
def api_rotate_token(uid):
    import secrets as sec
    token=sec.token_hex(16)
    c=get_db(); c.execute("UPDATE users SET token=? WHERE id=?",(token,uid)); c.commit(); c.close()
    doh_url=_build_doh_url(token)
    return jsonify({'ok':True,'message':'Token rotated','doh_url':doh_url})

@app.route('/api/dnstt',methods=['POST'])
@require_admin
def api_save_dnstt():
    data=request.json or {}
    ip=data.get('ip','').strip(); port=data.get('port','53').strip()
    if not ip: return jsonify({'ok':False,'message':'IP required'})
    env=open(ENV).read()
    if 'DNSTT_SERVER_IP=' in env:
        import re
        env=re.sub(r'^DNSTT_SERVER_IP=.*$',f'DNSTT_SERVER_IP={ip}',env,flags=re.M)
        env=re.sub(r'^DNSTT_DNS_PORT=.*$',f'DNSTT_DNS_PORT={port}',env,flags=re.M)
    else:
        env+=f"\nDNSTT_SERVER_IP={ip}\nDNSTT_DNS_PORT={port}\n"
    open(ENV,'w').write(env)
    return jsonify({'ok':True,'message':f'DNSTT server saved: {ip}:{port}'})

@app.route('/api/templates',methods=['POST'])
@require_admin
def api_add_template():
    data=request.json or {}
    url=data.get('url','').strip()
    if not url.startswith('slipnet://'): return jsonify({'ok':False,'message':'Must start with slipnet://'})
    try:
        b64=url[len('slipnet://'):]
        b64+='='*(-len(b64)%4)
        parts=base64.b64decode(b64).decode().split('|')
        if len(parts)<3: return jsonify({'ok':False,'message':'Invalid URL format'})
        proto=parts[1]; domain=parts[2]
        orig_b64=url[len('slipnet://'):]
        needs_stub=1 if proto in ('dnstt','dnstt_ssh','sayedns','sayedns_ssh') else 0
        c=get_db()
        ex=c.execute("SELECT id FROM slipnet_templates WHERE proto_type=? AND tunnel_domain=?",(proto,domain)).fetchone()
        if ex:
            c.execute("UPDATE slipnet_templates SET raw_b64=?,needs_stub=? WHERE id=?",(orig_b64,needs_stub,ex['id']))
        else:
            c.execute("INSERT INTO slipnet_templates(proto_type,tunnel_domain,raw_b64,needs_stub) VALUES(?,?,?,?)",(proto,domain,orig_b64,needs_stub))
        c.commit(); c.close()
        # Add stub-zone if needed
        msg=f"Saved: {proto} / {domain}"
        if needs_stub:
            dip=get_env('DNSTT_SERVER_IP'); dport=get_env('DNSTT_DNS_PORT') or '53'
            if dip:
                unbound_conf=open('/etc/unbound/unbound.conf').read()
                if f'name: "{domain}"' not in unbound_conf:
                    with open('/etc/unbound/unbound.conf','a') as f:
                        f.write(f'\nstub-zone:\n    name: "{domain}"\n    stub-addr: {dip}@{dport}\n')
                    import subprocess as sp
                    sp.run(['systemctl','restart','unbound'])
                    msg+=f' + stub-zone added'
            else: msg+=' (set DNSTT server IP to auto-add stub-zone)'
        return jsonify({'ok':True,'message':msg})
    except Exception as e: return jsonify({'ok':False,'message':str(e)})

@app.route('/api/templates/<int:tid>',methods=['DELETE'])
@require_admin
def api_delete_template(tid):
    c=get_db(); c.execute("DELETE FROM slipnet_templates WHERE id=?",(tid,)); c.commit(); c.close()
    return jsonify({'ok':True,'message':'Template deleted'})

@app.route('/api/gen-configs')
@require_admin
def api_gen_configs():
    c=get_db()
    users=c.execute("SELECT name,token FROM users WHERE active=1 ORDER BY id").fetchall()
    has_t=c.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='slipnet_templates'").fetchone()
    templates=c.execute("SELECT proto_type,raw_b64 FROM slipnet_templates ORDER BY id").fetchall() if has_t else []
    c.close()
    if not templates: return jsonify({'ok':False,'message':'No templates. Add via SlipNet tab.'})
    out=[]
    for u in users:
        doh_url=_build_doh_url(u['token'])
        out.append(f"── {u['name']}\n   DoH: {doh_url}")
        for t in templates:
            proto,domain,new_url=_process_slipnet(f"slipnet://{t['raw_b64']}",doh_url)
            if new_url: out.append(f"   [{t['proto_type']}] {new_url}")
        out.append('')
    return jsonify({'ok':True,'output':'\n'.join(out)})

@app.route('/api/gen-configs/<int:uid>')
@require_admin
def api_gen_configs_user(uid):
    c=get_db()
    u=c.execute("SELECT name,token FROM users WHERE id=? AND active=1",(uid,)).fetchone()
    has_t=c.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='slipnet_templates'").fetchone()
    templates=c.execute("SELECT proto_type,raw_b64 FROM slipnet_templates ORDER BY id").fetchall() if has_t else []
    c.close()
    if not u: return jsonify({'ok':False,'message':'User not found'})
    doh_url=_build_doh_url(u['token'])
    out=[f"── {u['name']}\n   DoH: {doh_url}"]
    for t in templates:
        proto,domain,new_url=_process_slipnet(f"slipnet://{t['raw_b64']}",doh_url)
        if new_url: out.append(f"   [{t['proto_type']}] {new_url}")
    return jsonify({'ok':True,'output':'\n'.join(out)})

@app.route('/api/test-stub')
@require_admin
def api_test_stub():
    import subprocess as sp
    c=get_db()
    has_t=c.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='slipnet_templates'").fetchone()
    domains=c.execute("SELECT tunnel_domain FROM slipnet_templates WHERE needs_stub=1").fetchall() if has_t else []
    c.close()
    out=[]
    for row in domains:
        dom=row['tunnel_domain']
        r=sp.run(['dig','@127.0.0.1','-p','5335',f'testxyz.{dom}','TXT','+time=3','+tries=1'],
                  capture_output=True,text=True)
        ok='aa' in r.stdout
        out.append(f"{'✅' if ok else '❌'} {dom}: {'Authoritative (OK)' if ok else 'No aa flag'}")
    if not out: out=['No DNSTT templates with stub-zone found.']
    return jsonify({'ok':True,'output':'\n'.join(out)})

@app.route('/api/rotate-prefix',methods=['POST'])
@require_admin
def api_rotate_prefix():
    import secrets as sec,subprocess as sp
    new_prefix=sec.token_hex(8)
    env=open(ENV).read()
    import re
    env=re.sub(r'^DOH_PREFIX=.*$',f'DOH_PREFIX={new_prefix}',env,flags=re.M)
    open(ENV,'w').write(env)
    sp.Popen(['bash','/opt/stealth-doh/deploy_worker.sh'])
    sp.run(['systemctl','restart','stealth-doh'])
    return jsonify({'ok':True,'message':f'Prefix rotated to {new_prefix}. Worker redeploying...'})

@app.route('/api/deploy-worker',methods=['POST'])
@require_admin
def api_deploy_worker():
    import subprocess as sp
    r=sp.run(['bash','/opt/stealth-doh/deploy_worker.sh'],capture_output=True,text=True)
    ok=r.returncode==0
    return jsonify({'ok':ok,'message':r.stdout.strip() if ok else r.stderr.strip()})

@app.route('/api/change-password',methods=['POST'])
@require_admin
def api_change_password():
    data=request.json or {}
    p=data.get('password','')
    if len(p)<8: return jsonify({'ok':False,'message':'Too short'})
    h=hashlib.sha256(p.encode()).hexdigest()
    import re,subprocess as sp
    env=open(ENV).read()
    env=re.sub(r'^ADMIN_PASS_HASH=.*$',f'ADMIN_PASS_HASH={h}',env,flags=re.M)
    open(ENV,'w').write(env)
    sp.run(['systemctl','restart','stealth-doh'])
    return jsonify({'ok':True,'message':'Password changed'})

@app.route('/api/backup',methods=['POST'])
@require_admin
def api_backup():
    import subprocess as sp,datetime
    ts=datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    bk=f'/root/stealth-doh-backup-{ts}.tar.gz'
    sp.run(['tar','-czf',bk,ENV,f'{BASE}/db/',f'{BASE}/VERSION'],capture_output=True)
    return jsonify({'ok':True,'message':f'Backup saved: {bk}'})

@app.route('/api/restart',methods=['POST'])
@require_admin
def api_restart():
    import subprocess as sp
    sp.run(['systemctl','restart','unbound','stealth-doh','nginx'])
    return jsonify({'ok':True,'message':'Services restarted'})

@app.route('/api/version')
@require_admin
def api_version():
    ver=open(f'{BASE}/VERSION').read().strip() if os.path.exists(f'{BASE}/VERSION') else '?'
    gh=get_env('GITHUB_REPO')
    out=[f"Installed: v{ver}"]
    if gh:
        import urllib.request
        try:
            latest=urllib.request.urlopen(f"{gh}/VERSION",timeout=5).read().decode().strip()
            if latest==ver: out.append(f"Latest: {latest} ✅ Up to date")
            else: out.append(f"Latest: {latest} ⚠ Update available\nRun: stealth-doh update")
        except: out.append("Cannot reach GitHub")
    else: out.append("GITHUB_REPO not configured")
    return jsonify({'ok':True,'output':'\n'.join(out)})

@app.route('/api/query-logs')
@require_admin
def api_query_logs():
    c=get_db()
    rows=c.execute("SELECT ts,user_name,domain,qtype,status,latency_ms FROM logs ORDER BY id DESC LIMIT 50").fetchall()
    c.close()
    return jsonify({'ok':True,'logs':[dict(r) for r in rows]})

@app.route('/panel/logout')
def logout(): session.clear(); return redirect(url_for('panel'))

@app.route('/health')
def health(): return Response('OK',200)

if __name__=='__main__':
    app.run(host='127.0.0.1',port=5000,debug=False)
PYEOF
    chmod +x "$BASE/app.py"
}

# ════════════════════════════════════════════════════
# MAIN dispatcher
# ════════════════════════════════════════════════════
print_header() {
    echo -e "${CYAN}${BOLD}"
    echo "  ╔══════════════════════════════════════════════╗"
    echo "  ║  Stealth DoH v${SCRIPT_VERSION}                         ║"
    echo "  ╚══════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_header
case "${1:-menu}" in
    install)          cmd_install ;;
    menu)             cmd_menu ;;
    status)           cmd_status ;;
    start)            cmd_start ;;
    stop)             cmd_stop ;;
    restart)          cmd_restart ;;
    logs)             cmd_logs ;;
    logs-follow)      cmd_logs_follow ;;
    query-logs)       cmd_query_logs ;;
    users)            cmd_users ;;
    add-user)         cmd_add_user ;;
    delete-user)      cmd_delete_user ;;
    rotate-token)     cmd_rotate_token ;;
    add-dnstt)        cmd_add_dnstt ;;
    gen-configs)      cmd_gen_configs ;;
    gen-configs-user) cmd_gen_configs_user ;;
    list-templates)   cmd_list_templates ;;
    test-stub)        cmd_test_stub ;;
    show-worker)      cmd_show_worker ;;
    rotate-prefix)    cmd_rotate_prefix ;;
    deploy-worker)    cmd_deploy_worker ;;
    change-password)  cmd_change_password ;;
    backup)           cmd_backup ;;
    uninstall)        cmd_uninstall ;;
    version)          cmd_version ;;
    update)           cmd_update ;;
    _migrate)         cmd_migrate ;;
    help)             cmd_help ;;
    *)                cmd_menu ;;
esac
