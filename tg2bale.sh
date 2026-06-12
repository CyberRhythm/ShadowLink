#!/bin/bash
# ================================================================
#  ShadowLink — Telegram to Bale File Bridge
#  https://github.com/CyberRhythm/ShadowLink
# ================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

GITHUB_URL="https://github.com/CyberRhythm/ShadowLink"
INSTALL_DIR="/opt/tg2bale"
SERVICE_NAME="tg2bale"

# ── UI helpers ────────────────────────────────────────────────
print_banner() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "   ░██████╗██╗░░██╗░█████╗░██████╗░░█████╗░░██╗░░░░░░░██╗██╗░░░░░██╗███╗░░██╗██╗░░██╗"
    echo "   ██╔════╝██║░░██║██╔══██╗██╔══██╗██╔══██╗░██║░░██╗░░██║██║░░░░░██║████╗░██║██║░██╔╝"
    echo "   ╚█████╗░███████║███████║██║░░██║██║░░██║░╚██╗████╗██╔╝██║░░░░░██║██╔██╗██║█████═╝░"
    echo "   ░╚═══██╗██╔══██║██╔══██║██║░░██║██║░░██║░░████╔═████║░██║░░░░░██║██║╚████║██╔═██╗░"
    echo "   ██████╔╝██║░░██║██║░░██║██████╔╝╚█████╔╝░░╚██╔╝░╚██╔╝░███████╗██║██║░╚███║██║░╚██╗"
    echo "   ╚═════╝░╚═╝░░╚═╝╚═╝░░╚═╝╚═════╝░░╚════╝░░░░╚═╝░░░╚═╝░╚══════╝╚═╝╚═╝░░╚══╝╚═╝░░╚═╝"
    echo -e "${NC}"
    echo -e "  ${DIM}  Telegram → Bale File Bridge  |  ${CYAN}${GITHUB_URL}${NC}"
    echo -e "  ${DIM}  ──────────────────────────────────────────────────────${NC}"
    echo ""
}

divider()      { echo -e "  ${CYAN}────────────────────────────────────────────────${NC}"; }
thin_divider() { echo -e "  ${DIM}────────────────────────────────────────────────${NC}"; }
print_ok()     { echo -e "  ${GREEN}✓${NC}  $1"; }
print_warn()   { echo -e "  ${YELLOW}!${NC}  $1"; }
print_error()  { echo -e "  ${RED}✗${NC}  $1"; }
print_info()   { echo -e "  ${CYAN}→${NC}  $1"; }
print_step()   { echo -e "\n  ${MAGENTA}${BOLD}[$1]${NC}  $2"; thin_divider; }

ask() {
    echo -ne "\n  ${BOLD}$1${NC}  "
    read -r "$2"
}

confirm() {
    echo -ne "\n  ${YELLOW}$1 [y/N]:${NC}  "
    read -r _ans
    [[ "$_ans" =~ ^[Yy]$ ]]
}

pause() {
    echo -ne "\n  ${DIM}Press Enter to continue...${NC}"
    read -r
}

spinner() {
    local pid=$1 msg=$2
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  ${CYAN}${spin:$i:1}${NC}  %s" "$msg"
        i=$(( (i+1) % 10 ))
        sleep 0.08
    done
    printf "\r  ${GREEN}✓${NC}  %-50s\n" "$msg"
}

run_silent() {
    local msg="$1"; shift
    "$@" > /tmp/sl_out 2>&1 &
    spinner $! "$msg"
}

svc_active() {
    systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null
}

status_badge() {
    if svc_active; then
        echo -e "${GREEN}● running${NC}"
    else
        echo -e "${RED}● stopped${NC}"
    fi
}

# ── Write bot.py ──────────────────────────────────────────────
write_bot_py() {
    cat > "${INSTALL_DIR}/bot.py" << 'BOTEOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# ShadowLink — https://github.com/CyberRhythm/ShadowLink

import asyncio, logging, os, tempfile, aiohttp, aiofiles
from datetime import datetime
from collections import deque
import pytz, jdatetime
from dotenv import load_dotenv

load_dotenv(os.path.join(os.path.dirname(__file__), ".env"))

TELEGRAM_TOKEN        = os.getenv("TELEGRAM_TOKEN")
BALE_TOKEN            = os.getenv("BALE_TOKEN")
ALLOWED_TELEGRAM_USER = int(os.getenv("ALLOWED_TELEGRAM_USER"))
ALLOWED_BALE_USER     = int(os.getenv("ALLOWED_BALE_USER"))
LOG_FILE              = os.getenv("LOG_FILE", os.path.join(os.path.dirname(__file__), "bot.log"))

TELEGRAM_API = f"https://api.telegram.org/bot{TELEGRAM_TOKEN}"
BALE_API     = f"https://tapi.bale.ai/bot{BALE_TOKEN}"
IRAN_TZ      = pytz.timezone("Asia/Tehran")

BLOCKED_EXT = {".apk",".exe",".msi",".bat",".cmd",".sh",".deb",".rpm",".dmg",".pkg",".ipa"}

logging.basicConfig(level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.FileHandler(LOG_FILE, encoding="utf-8"), logging.StreamHandler()])
log = logging.getLogger(__name__)

FILE_QUEUE = deque()
QUEUE_LOCK = asyncio.Lock()
SEND_SEM   = asyncio.Semaphore(1)

def iran_now():
    now = datetime.now(IRAN_TZ)
    jdt = jdatetime.datetime.fromgregorian(datetime=now)
    months = ["","فروردین","اردیبهشت","خرداد","تیر","مرداد","شهریور","مهر","آبان","آذر","دی","بهمن","اسفند"]
    days   = ["دوشنبه","سه‌شنبه","چهارشنبه","پنج‌شنبه","جمعه","شنبه","یکشنبه"]
    return f"{days[now.weekday()]} {jdt.day} {months[jdt.month]} {jdt.year}  ساعت {jdt.hour:02d}:{jdt.minute:02d}:{jdt.second:02d}"

def pbar(cur, tot, w=12):
    f = int(w*cur/tot) if tot else 0
    return f"[{'█'*f}{'░'*(w-f)}] {int(100*cur/tot) if tot else 0}%"

def safe_name(n):
    _, e = os.path.splitext(n.lower())
    return (n+".bin", True) if e in BLOCKED_EXT else (n, False)

async def send_msg(s, text):
    try:
        async with s.post(f"{TELEGRAM_API}/sendMessage",
            json={"chat_id":ALLOWED_TELEGRAM_USER,"text":text,"parse_mode":"Markdown"},
            timeout=aiohttp.ClientTimeout(total=15)) as r:
            d = await r.json()
            return d["result"]["message_id"] if d.get("ok") else None
    except: return None

async def edit_msg(s, mid, text):
    try:
        async with s.post(f"{TELEGRAM_API}/editMessageText",
            json={"chat_id":ALLOWED_TELEGRAM_USER,"message_id":mid,"text":text,"parse_mode":"Markdown"},
            timeout=aiohttp.ClientTimeout(total=15)) as r: pass
    except: pass

async def dl(s, fid, dest):
    try:
        async with s.get(f"{TELEGRAM_API}/getFile", params={"file_id":fid},
            timeout=aiohttp.ClientTimeout(total=30)) as r:
            d = await r.json()
            if not d.get("ok"): return False
            fp = d["result"]["file_path"]
        async with s.get(f"https://api.telegram.org/file/bot{TELEGRAM_TOKEN}/{fp}",
            timeout=aiohttp.ClientTimeout(total=600)) as r:
            if r.status != 200: return False
            async with aiofiles.open(dest,"wb") as f:
                async for chunk in r.content.iter_chunked(131072): await f.write(chunk)
        return True
    except Exception as e: log.error("dl error: %s", e); return False

async def ul(s, path, name, cap=""):
    for attempt in range(1,4):
        try:
            async with aiofiles.open(path,"rb") as f: data = await f.read()
            form = aiohttp.FormData()
            form.add_field("chat_id", str(ALLOWED_BALE_USER))
            form.add_field("document", data, filename=name, content_type="application/octet-stream")
            if cap: form.add_field("caption", cap)
            async with s.post(f"{BALE_API}/sendDocument", data=form,
                timeout=aiohttp.ClientTimeout(total=600)) as r:
                d = await r.json()
                if d.get("ok"): return True
                log.warning("bale reject (try %d): %s", attempt, d)
        except Exception as e: log.error("ul error (try %d): %s", attempt, e)
        await asyncio.sleep(3*attempt)
    return False

def extract(msg):
    cap = msg.get("caption","")
    for k in ["document","video","audio","voice","animation"]:
        if k in msg:
            o = msg[k]; n = o.get("file_name") or f"{k}_{o['file_unique_id']}"
            return {"file_id":o["file_id"],"file_name":n,"caption":cap}
    if "photo" in msg:
        best = max(msg["photo"], key=lambda p: p.get("file_size",0))
        return {"file_id":best["file_id"],"file_name":"photo.jpg","caption":cap}
    return None

async def worker(s):
    log.info("queue worker ready")
    mid=None; done=0; ok=0; fail=0
    while True:
        if not FILE_QUEUE: await asyncio.sleep(0.3); continue
        async with SEND_SEM:
            async with QUEUE_LOCK:
                if not FILE_QUEUE: continue
                item = FILE_QUEUE.popleft()
            fn=item["file_name"]; fid=item["file_id"]; cap=item.get("caption","")
            now=iran_now(); rem=len(FILE_QUEUE)
            bn, renamed = safe_name(fn)
            fc = cap
            if renamed:
                note = f"⚠️ نام اصلی: {fn}\nپسوند .bin را از انتهای نام حذف کنید"
                fc = (cap+"\n\n"+note).strip() if cap else note
            log.info("processing: %s (queue: %d)", fn, rem)
            qi = f"\n📋 {rem} فایل دیگر در صف" if rem>0 else ""
            live = f"⬇️ *در حال دانلود...*\n\n📄 `{fn}`{qi}\n🕐 {now}"
            if mid is None: mid = await send_msg(s, live)
            else: await edit_msg(s, mid, live)
            ext = os.path.splitext(fn)[1] or ".bin"
            tmp = tempfile.mktemp(suffix=ext)
            got = await dl(s, fid, tmp)
            if not got:
                fail+=1; done+=1
                if mid: await edit_msg(s, mid, f"❌ *دانلود ناموفق*\n\n📄 `{fn}`\n🕐 {iran_now()}")
                if len(FILE_QUEUE)==0: mid=None; done=0; ok=0; fail=0
                continue
            qi = f"\n📋 {rem} فایل دیگر در صف" if rem>0 else ""
            if mid: await edit_msg(s, mid, f"📤 *در حال ارسال به بله...*\n\n📄 `{fn}`{qi}\n🕐 {now}")
            sent = await ul(s, tmp, bn, fc)
            try: os.unlink(tmp)
            except: pass
            done+=1
            if sent: ok+=1; log.info("✅ %s", fn)
            else: fail+=1; log.error("❌ %s", fn)
            fnow=iran_now(); rnow=len(FILE_QUEUE)
            if rnow==0:
                if done==1:
                    if sent:
                        f2 = f"✅ *ارسال موفق بود*\n\n📄 `{fn}`\n"
                        if renamed: f2 += f"⚠️ پسوند تغییر کرد: `{bn}`\n"
                        f2 += f"🕐 {fnow}"
                    else: f2 = f"❌ *ارسال ناموفق بود*\n\n📄 `{fn}`\n🕐 {fnow}"
                else:
                    st = "✅ تمام ارسال‌ها موفق بودند" if fail==0 else f"⚠️ {ok} موفق — {fail} ناموفق"
                    f2 = f"📦 *نتیجه ارسال {done} فایل*\n\n{pbar(ok,done)}  {ok} از {done}\n\n{st}\n🕐 {fnow}"
                if mid: await edit_msg(s, mid, f2)
                mid=None; done=0; ok=0; fail=0
            else:
                icon="✅" if sent else "❌"
                if mid: await edit_msg(s, mid,
                    f"{icon} `{fn}`\n\n⏳ *{rnow} فایل دیگر در صف...*\n✅ {ok} موفق  ❌ {fail} ناموفق\n🕐 {fnow}")

async def get_updates(s, offset):
    try:
        async with s.get(f"{TELEGRAM_API}/getUpdates",
            params={"offset":offset,"timeout":30},
            timeout=aiohttp.ClientTimeout(total=40)) as r:
            d = await r.json()
            return d.get("result",[]) if d.get("ok") else []
    except Exception as e: log.error("getUpdates: %s", e); return []

async def main():
    log.info("ShadowLink started 🚀 | TG:%s | Bale:%s", ALLOWED_TELEGRAM_USER, ALLOWED_BALE_USER)
    offset=0
    async with aiohttp.ClientSession() as s:
        asyncio.create_task(worker(s))
        while True:
            updates = await get_updates(s, offset)
            for u in updates:
                offset = u["update_id"]+1
                msg = u.get("message")
                if not msg: continue
                if msg.get("from",{}).get("id") != ALLOWED_TELEGRAM_USER: continue
                fi = extract(msg)
                if not fi: continue
                async with QUEUE_LOCK: FILE_QUEUE.append(fi)
                log.info("queued: %s (%d)", fi["file_name"], len(FILE_QUEUE))
            if not updates: await asyncio.sleep(0.3)

if __name__ == "__main__":
    asyncio.run(main())
BOTEOF
}

# ── Install ───────────────────────────────────────────────────
do_install() {
    print_banner
    echo -e "  ${BOLD}Setup — Enter your credentials${NC}"
    divider
    echo ""

    ask "Telegram Bot Token :" TG_TOKEN
    ask "Telegram User ID   :" TG_UID
    ask "Bale Bot Token     :" BALE_TOKEN
    ask "Bale User ID       :" BALE_UID

    echo ""
    divider
    echo -e "  ${BOLD}Review:${NC}"
    thin_divider
    echo -e "  Telegram Token : ${DIM}${TG_TOKEN:0:28}...${NC}"
    echo -e "  Telegram UID   : ${YELLOW}${TG_UID}${NC}"
    echo -e "  Bale Token     : ${DIM}${BALE_TOKEN:0:28}...${NC}"
    echo -e "  Bale UID       : ${YELLOW}${BALE_UID}${NC}"
    echo -e "  Install path   : ${DIM}${INSTALL_DIR}${NC}"
    divider

    confirm "Proceed with installation?" || { echo ""; print_warn "Cancelled."; exit 0; }

    echo ""
    print_step "1" "Updating system"
    run_silent "Refreshing package lists   " apt-get update -qq
    run_silent "Installing Python3         " apt-get install -y -qq python3 python3-venv python3-pip curl

    print_step "2" "Preparing directory"
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        systemctl stop "$SERVICE_NAME" 2>/dev/null || true
        systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    fi
    rm -rf "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    print_ok "Directory ready: ${INSTALL_DIR}"

    print_step "3" "Setting up Python environment"
    run_silent "Creating virtual environment" python3 -m venv "${INSTALL_DIR}/venv"
    run_silent "Installing dependencies    " \
        "${INSTALL_DIR}/venv/bin/pip" install --quiet --upgrade pip aiohttp aiofiles pytz jdatetime python-dotenv

    print_step "4" "Writing configuration"
    cat > "${INSTALL_DIR}/.env" << EOF
TELEGRAM_TOKEN=${TG_TOKEN}
BALE_TOKEN=${BALE_TOKEN}
ALLOWED_TELEGRAM_USER=${TG_UID}
ALLOWED_BALE_USER=${BALE_UID}
LOG_FILE=${INSTALL_DIR}/bot.log
EOF
    chmod 600 "${INSTALL_DIR}/.env"
    print_ok ".env written  (chmod 600)"

    write_bot_py
    print_ok "bot.py written"

    print_step "5" "Registering system service"
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=ShadowLink — Telegram to Bale Bridge
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/venv/bin/python3 ${INSTALL_DIR}/bot.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload > /dev/null 2>&1
    systemctl enable "$SERVICE_NAME" --quiet
    systemctl start "$SERVICE_NAME"
    sleep 2

    print_step "6" "Verifying"
    if svc_active; then
        print_ok "Service is live!"
        echo ""
        echo -e "  ${GREEN}${BOLD}  ╔════════════════════════════════════════╗"
        echo -e "  ║   ShadowLink installed successfully!   ║"
        echo -e "  ╚════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "  ${DIM}Send a file to your Telegram bot to test.${NC}"
        echo -e "  ${DIM}Logs: journalctl -u ${SERVICE_NAME} -f${NC}"
        echo ""
    else
        print_error "Service failed to start."
        echo -e "\n  Debug: ${CYAN}journalctl -u ${SERVICE_NAME} -n 30${NC}"
        exit 1
    fi
    pause
}

# ── Main menu ─────────────────────────────────────────────────
main_menu() {
    while true; do
        print_banner
        echo -e "  ${BOLD}Status:${NC}  $(status_badge)"
        echo ""
        divider
        echo -e "  ${BOLD}[1]${NC}  ▶   Start"
        echo -e "  ${BOLD}[2]${NC}  ⏹   Stop"
        echo -e "  ${BOLD}[3]${NC}  🔄  Restart"
        echo -e "  ${BOLD}[4]${NC}  📋  Live logs"
        echo -e "  ${BOLD}[5]${NC}  🔧  View config"
        echo -e "  ${BOLD}[6]${NC}  ♻️   Reinstall"
        echo -e "  ${BOLD}[0]${NC}  ✕   Exit"
        divider
        echo ""
        ask "Option:" opt

        case "$opt" in
            1) systemctl start   "$SERVICE_NAME" && print_ok "Started."   || print_error "Failed."; pause ;;
            2) systemctl stop    "$SERVICE_NAME" && print_ok "Stopped."   || print_error "Failed."; pause ;;
            3) systemctl restart "$SERVICE_NAME" && print_ok "Restarted." || print_error "Failed."; pause ;;
            4) echo ""; print_info "Ctrl+C to exit logs"; sleep 1; journalctl -u "$SERVICE_NAME" -f ;;
            5) echo ""; cat "${INSTALL_DIR}/.env"; pause ;;
            6) do_install ;;
            0) echo ""; echo -e "  ${GREEN}Goodbye.${NC}"; echo ""; exit 0 ;;
            *) print_error "Invalid option."; sleep 1 ;;
        esac
    done
}

# ── Entry point ───────────────────────────────────────────────
[[ $EUID -ne 0 ]] && {
    print_banner
    print_error "Run as root:  sudo bash tg2bale.sh"
    exit 1
}

# اگه قبلاً نصب شده → منو، وگرنه → نصب
if [[ -f "${INSTALL_DIR}/bot.py" ]]; then
    main_menu
else
    do_install
    main_menu
fi
