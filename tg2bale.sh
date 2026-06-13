#!/bin/bash
# ================================================================
#  ShadowLink — Telegram to Bale File Bridge
#  https://github.com/CyberRhythm/ShadowLink
# ================================================================

# Fail on errors and unset vars, and propagate failures through pipes.
set -Eeuo pipefail
trap 'print_error "Unexpected error on line $LINENO (exit $?)."' ERR

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
    clear 2>/dev/null || true
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
        sleep 0.08 || true
    done
    printf "\r  ${GREEN}✓${NC}  %-50s\n" "$msg"
}

run_silent() {
    # Run a command quietly with a spinner; surface failures clearly
    # instead of letting `set -e` abort with no context.
    local msg="$1"; shift
    "$@" > /tmp/sl_out 2>&1 &
    local pid=$!
    spinner "$pid" "$msg"
    if ! wait "$pid"; then
        print_error "$msg — failed"
        echo -e "  ${DIM}$(tail -n 5 /tmp/sl_out 2>/dev/null)${NC}"
        return 1
    fi
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
# ShadowLink — Telegram → Bale file bridge
# https://github.com/CyberRhythm/ShadowLink
#
# Professional rewrite: robust error handling, pre-download size guard
# (saves bandwidth on bad connections), smart retry/backoff, FloodWait-safe
# message editing, clean per-batch statistics, structured logging.

import asyncio
import logging
import os
import sys
import tempfile
from collections import deque
from datetime import datetime

import aiohttp
import aiofiles
import pytz
import jdatetime
from dotenv import load_dotenv

# ── Configuration ─────────────────────────────────────────────
load_dotenv(os.path.join(os.path.dirname(__file__), ".env"))


def _require_int(name: str) -> int:
    """Read a mandatory integer env var, failing fast with a clear message."""
    raw = os.getenv(name)
    if raw is None or raw.strip() == "":
        sys.exit(f"[FATAL] Missing required env var: {name}")
    try:
        return int(raw.strip())
    except ValueError:
        sys.exit(f"[FATAL] Env var {name} must be an integer, got: {raw!r}")


def _require_str(name: str) -> str:
    raw = os.getenv(name)
    if not raw or not raw.strip():
        sys.exit(f"[FATAL] Missing required env var: {name}")
    return raw.strip()


TELEGRAM_TOKEN = _require_str("TELEGRAM_TOKEN")
BALE_TOKEN = _require_str("BALE_TOKEN")
ALLOWED_TELEGRAM_USER = _require_int("ALLOWED_TELEGRAM_USER")
ALLOWED_BALE_USER = _require_int("ALLOWED_BALE_USER")
LOG_FILE = os.getenv("LOG_FILE", os.path.join(os.path.dirname(__file__), "bot.log"))

# Telegram Bot API can only download files up to 20 MB via getFile.
# Bale's sendDocument practically rejects very large files too.
# We pre-check the size so we NEVER waste bandwidth downloading something
# we cannot forward — this is the core fix for poor-connectivity users.
TELEGRAM_DOWNLOAD_LIMIT = 20 * 1024 * 1024          # 20 MB hard API limit
BALE_UPLOAD_LIMIT = int(os.getenv("BALE_UPLOAD_LIMIT", str(50 * 1024 * 1024)))  # 50 MB default

TELEGRAM_API = f"https://api.telegram.org/bot{TELEGRAM_TOKEN}"
BALE_API = f"https://tapi.bale.ai/bot{BALE_TOKEN}"
IRAN_TZ = pytz.timezone("Asia/Tehran")

BLOCKED_EXT = {".apk", ".exe", ".msi", ".bat", ".cmd", ".sh",
               ".deb", ".rpm", ".dmg", ".pkg", ".ipa"}

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.FileHandler(LOG_FILE, encoding="utf-8"),
        logging.StreamHandler(),
    ],
)
log = logging.getLogger("shadowlink")

# ── Shared state ──────────────────────────────────────────────
FILE_QUEUE: "deque[dict]" = deque()
QUEUE_LOCK = asyncio.Lock()

# ── Helpers ───────────────────────────────────────────────────
def iran_now() -> str:
    now = datetime.now(IRAN_TZ)
    jdt = jdatetime.datetime.fromgregorian(datetime=now)
    months = ["", "فروردین", "اردیبهشت", "خرداد", "تیر", "مرداد", "شهریور",
              "مهر", "آبان", "آذر", "دی", "بهمن", "اسفند"]
    # datetime.weekday(): 0=Monday … 6=Sunday
    days = ["دوشنبه", "سه‌شنبه", "چهارشنبه", "پنج‌شنبه", "جمعه", "شنبه", "یکشنبه"]
    return (f"{days[now.weekday()]} {jdt.day} {months[jdt.month]} {jdt.year}"
            f"  ساعت {jdt.hour:02d}:{jdt.minute:02d}:{jdt.second:02d}")


def human_size(num: float) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if num < 1024 or unit == "TB":
            return f"{num:.1f} {unit}"
        num /= 1024
    return f"{num:.1f} TB"


def pbar(cur: int, tot: int, w: int = 12) -> str:
    filled = int(w * cur / tot) if tot else 0
    pct = int(100 * cur / tot) if tot else 0
    return f"[{'█' * filled}{'░' * (w - filled)}] {pct}%"


def safe_name(name: str):
    """Append .bin to extensions Bale would reject. Returns (new_name, renamed)."""
    _, ext = os.path.splitext(name.lower())
    if ext in BLOCKED_EXT:
        return name + ".bin", True
    return name, False


# ── Telegram messaging (resilient) ────────────────────────────
async def _post_json(session, endpoint: str, payload: dict, timeout: int = 15):
    """POST JSON to Telegram with basic 429/FloodWait awareness."""
    for attempt in range(1, 4):
        try:
            async with session.post(endpoint, json=payload,
                                    timeout=aiohttp.ClientTimeout(total=timeout)) as r:
                data = await r.json()
                if r.status == 429:
                    retry_after = data.get("parameters", {}).get("retry_after", 2)
                    log.warning("Telegram 429, sleeping %ss", retry_after)
                    await asyncio.sleep(retry_after + 1)
                    continue
                return data
        except (aiohttp.ClientError, asyncio.TimeoutError) as e:
            log.warning("telegram post error (try %d): %s", attempt, e)
            await asyncio.sleep(1.5 * attempt)
    return None


async def send_msg(session, text: str):
    data = await _post_json(session, f"{TELEGRAM_API}/sendMessage",
                            {"chat_id": ALLOWED_TELEGRAM_USER, "text": text,
                             "parse_mode": "Markdown"})
    if data and data.get("ok"):
        return data["result"]["message_id"]
    return None


async def edit_msg(session, message_id, text: str):
    if message_id is None:
        return
    await _post_json(session, f"{TELEGRAM_API}/editMessageText",
                     {"chat_id": ALLOWED_TELEGRAM_USER, "message_id": message_id,
                      "text": text, "parse_mode": "Markdown"})


# ── File transfer ─────────────────────────────────────────────
async def get_file_path(session, file_id: str):
    """Resolve a Telegram file_id to its download path (also exposes size)."""
    data = await _post_json(session, f"{TELEGRAM_API}/getFile",
                            {"file_id": file_id}, timeout=30)
    if not data or not data.get("ok"):
        return None, None
    result = data["result"]
    return result.get("file_path"), result.get("file_size")


async def download(session, file_path: str, dest: str) -> bool:
    url = f"https://api.telegram.org/file/bot{TELEGRAM_TOKEN}/{file_path}"
    try:
        async with session.get(url, timeout=aiohttp.ClientTimeout(total=600)) as r:
            if r.status != 200:
                log.error("download HTTP %s", r.status)
                return False
            async with aiofiles.open(dest, "wb") as f:
                async for chunk in r.content.iter_chunked(131072):
                    await f.write(chunk)
        return True
    except (aiohttp.ClientError, asyncio.TimeoutError, OSError) as e:
        log.error("download error: %s", e)
        return False


async def upload_to_bale(session, path: str, name: str, caption: str = "") -> bool:
    """Upload to Bale with exponential backoff retry."""
    for attempt in range(1, 4):
        try:
            async with aiofiles.open(path, "rb") as f:
                data = await f.read()
            form = aiohttp.FormData()
            form.add_field("chat_id", str(ALLOWED_BALE_USER))
            form.add_field("document", data, filename=name,
                           content_type="application/octet-stream")
            if caption:
                form.add_field("caption", caption)
            async with session.post(f"{BALE_API}/sendDocument", data=form,
                                    timeout=aiohttp.ClientTimeout(total=600)) as r:
                resp = await r.json()
                if resp.get("ok"):
                    return True
                log.warning("bale rejected (try %d): %s", attempt, resp)
        except (aiohttp.ClientError, asyncio.TimeoutError, OSError) as e:
            log.error("upload error (try %d): %s", attempt, e)
        await asyncio.sleep(3 * attempt)  # 3s, 6s, 9s backoff
    return False


def extract_file(msg: dict):
    """Pull a forwardable file descriptor (incl. size) out of a Telegram message."""
    caption = msg.get("caption", "")
    for key in ("document", "video", "audio", "voice", "animation"):
        if key in msg:
            obj = msg[key]
            name = obj.get("file_name") or f"{key}_{obj.get('file_unique_id', 'file')}"
            return {"file_id": obj["file_id"], "file_name": name,
                    "file_size": obj.get("file_size", 0), "caption": caption}
    if "photo" in msg:
        best = max(msg["photo"], key=lambda p: p.get("file_size", 0))
        return {"file_id": best["file_id"], "file_name": "photo.jpg",
                "file_size": best.get("file_size", 0), "caption": caption}
    return None


# ── Queue worker ──────────────────────────────────────────────
async def worker(session):
    """Process queued files one-by-one and report batch results."""
    log.info("queue worker ready")
    status_mid = None
    done = ok = fail = 0

    while True:
        if not FILE_QUEUE:
            await asyncio.sleep(0.3)
            continue

        async with QUEUE_LOCK:
            if not FILE_QUEUE:
                continue
            item = FILE_QUEUE.popleft()

        file_name = item["file_name"]
        file_id = item["file_id"]
        caption = item.get("caption", "")
        declared_size = item.get("file_size", 0)
        remaining = len(FILE_QUEUE)
        bale_name, renamed = safe_name(file_name)

        log.info("processing: %s (%s, queue:%d)",
                 file_name, human_size(declared_size), remaining)

        queue_note = f"\n📋 {remaining} فایل دیگر در صف" if remaining else ""

        # ── Pre-download size guard (the core bandwidth fix) ──
        if declared_size and declared_size > TELEGRAM_DOWNLOAD_LIMIT:
            done += 1
            fail += 1
            text = (f"⚠️ *فایل خیلی بزرگ است*\n\n📄 `{file_name}`\n"
                    f"📦 حجم: `{human_size(declared_size)}`\n"
                    f"❗️ تلگرام اجازه دانلود فایل بزرگ‌تر از "
                    f"`{human_size(TELEGRAM_DOWNLOAD_LIMIT)}` را با ربات نمی‌دهد.\n"
                    f"💡 از بخش Tele2Server برای تقسیم فایل استفاده کنید.\n🕐 {iran_now()}")
            status_mid = (await send_msg(session, text)
                          if status_mid is None else status_mid)
            await edit_msg(session, status_mid, text)
            if not FILE_QUEUE:
                status_mid = None; done = ok = fail = 0
            continue

        # ── Resolve file path & verify real size ──
        live = f"⬇️ *در حال دانلود...*\n\n📄 `{file_name}`{queue_note}\n🕐 {iran_now()}"
        if status_mid is None:
            status_mid = await send_msg(session, live)
        else:
            await edit_msg(session, status_mid, live)

        file_path, real_size = await get_file_path(session, file_id)
        if file_path is None:
            done += 1; fail += 1
            await edit_msg(session, status_mid,
                           f"❌ *دانلود ناموفق*\n\n📄 `{file_name}`\n"
                           f"❗️ احتمالاً فایل بزرگ‌تر از حد مجاز تلگرام است.\n🕐 {iran_now()}")
            if not FILE_QUEUE:
                status_mid = None; done = ok = fail = 0
            continue

        ext = os.path.splitext(file_name)[1] or ".bin"
        fd, tmp = tempfile.mkstemp(suffix=ext)
        os.close(fd)  # we only need the unique path; aiofiles reopens it

        got = await download(session, file_path, tmp)
        if not got:
            done += 1; fail += 1
            _safe_unlink(tmp)
            await edit_msg(session, status_mid,
                           f"❌ *دانلود ناموفق*\n\n📄 `{file_name}`\n🕐 {iran_now()}")
            if not FILE_QUEUE:
                status_mid = None; done = ok = fail = 0
            continue

        # ── Upload to Bale ──
        await edit_msg(session, status_mid,
                       f"📤 *در حال ارسال به بله...*\n\n📄 `{file_name}`{queue_note}\n🕐 {iran_now()}")

        bale_caption = caption
        if renamed:
            note = f"⚠️ نام اصلی: {file_name}\nپسوند .bin را از انتهای نام حذف کنید"
            bale_caption = (caption + "\n\n" + note).strip() if caption else note

        sent = await upload_to_bale(session, tmp, bale_name, bale_caption)
        _safe_unlink(tmp)

        done += 1
        if sent:
            ok += 1; log.info("✅ sent: %s", file_name)
        else:
            fail += 1; log.error("❌ failed: %s", file_name)

        # ── Report ──
        remaining = len(FILE_QUEUE)
        if remaining == 0:
            if done == 1:
                if sent:
                    final = f"✅ *ارسال موفق بود*\n\n📄 `{file_name}`\n"
                    if renamed:
                        final += f"⚠️ پسوند تغییر کرد: `{bale_name}`\n"
                    final += f"🕐 {iran_now()}"
                else:
                    final = f"❌ *ارسال ناموفق بود*\n\n📄 `{file_name}`\n🕐 {iran_now()}"
            else:
                summary = ("✅ تمام ارسال‌ها موفق بودند" if fail == 0
                           else f"⚠️ {ok} موفق — {fail} ناموفق")
                final = (f"📦 *نتیجه ارسال {done} فایل*\n\n"
                         f"{pbar(ok, done)}  {ok} از {done}\n\n{summary}\n🕐 {iran_now()}")
            await edit_msg(session, status_mid, final)
            status_mid = None; done = ok = fail = 0
        else:
            icon = "✅" if sent else "❌"
            await edit_msg(session, status_mid,
                           f"{icon} `{file_name}`\n\n⏳ *{remaining} فایل دیگر در صف...*\n"
                           f"✅ {ok} موفق  ❌ {fail} ناموفق\n🕐 {iran_now()}")


def _safe_unlink(path: str):
    try:
        os.unlink(path)
    except OSError:
        pass


# ── Update polling ────────────────────────────────────────────
async def get_updates(session, offset: int):
    data = await _post_json(session, f"{TELEGRAM_API}/getUpdates",
                            {"offset": offset, "timeout": 30}, timeout=40)
    if data and data.get("ok"):
        return data["result"]
    return []


async def main():
    log.info("ShadowLink started 🚀 | TG:%s → Bale:%s",
             ALLOWED_TELEGRAM_USER, ALLOWED_BALE_USER)
    offset = 0
    async with aiohttp.ClientSession() as session:
        # Drop any backlog so we don't reprocess old files on restart.
        async with session.get(f"{TELEGRAM_API}/getUpdates",
                                params={"offset": -1},
                                timeout=aiohttp.ClientTimeout(total=15)) as r:
            try:
                d = await r.json()
                if d.get("ok") and d["result"]:
                    offset = d["result"][-1]["update_id"] + 1
            except (aiohttp.ContentTypeError, KeyError, IndexError):
                pass

        asyncio.create_task(worker(session))
        while True:
            updates = await get_updates(session, offset)
            for u in updates:
                offset = u["update_id"] + 1
                msg = u.get("message")
                if not msg:
                    continue
                if msg.get("from", {}).get("id") != ALLOWED_TELEGRAM_USER:
                    continue
                file_info = extract_file(msg)
                if not file_info:
                    continue
                async with QUEUE_LOCK:
                    FILE_QUEUE.append(file_info)
                log.info("queued: %s (queue:%d)", file_info["file_name"], len(FILE_QUEUE))
            if not updates:
                await asyncio.sleep(0.3)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        log.info("ShadowLink stopped by user")
BOTEOF
}

# ── Install ───────────────────────────────────────────────────
do_install() {
    print_banner
    echo -e "  ${BOLD}Setup — Enter your credentials${NC}"
    divider
    echo ""

    ask "Telegram Bot Token :" TG_TOKEN
    while ! [[ "$TG_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; do
        print_warn "Invalid token format. Should look like: 123456789:AAF..."
        ask "Telegram Bot Token :" TG_TOKEN
    done

    ask "Telegram User ID   :" TG_UID
    while ! [[ "$TG_UID" =~ ^[0-9]+$ ]]; do
        print_warn "User ID must be a number."
        ask "Telegram User ID   :" TG_UID
    done

    ask "Bale Bot Token     :" BALE_TOKEN
    while [ -z "$BALE_TOKEN" ]; do
        print_warn "Bale token is required."
        ask "Bale Bot Token     :" BALE_TOKEN
    done

    ask "Bale User ID       :" BALE_UID
    while ! [[ "$BALE_UID" =~ ^[0-9]+$ ]]; do
        print_warn "User ID must be a number."
        ask "Bale User ID       :" BALE_UID
    done

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
