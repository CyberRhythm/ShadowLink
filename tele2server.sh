#!/bin/bash
# ================================================================
#  Tele2Server — Telegram File Manager Bot
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
INSTALL_DIR="/opt/tele2server"
SERVICE_NAME="tele2server"

# ── UI helpers ────────────────────────────────────────────────
print_banner() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "  ████████╗███████╗██╗     ███████╗██████╗ ███████╗███████╗██████╗ ██╗   ██╗███████╗██████╗ "
    echo "     ██╔══╝██╔════╝██║     ██╔════╝╚════██╗██╔════╝██╔════╝██╔══██╗██║   ██║██╔════╝██╔══██╗"
    echo "     ██║   █████╗  ██║     █████╗   █████╔╝███████╗█████╗  ██████╔╝██║   ██║█████╗  ██████╔╝"
    echo "     ██║   ██╔══╝  ██║     ██╔══╝  ██╔═══╝ ╚════██║██╔══╝  ██╔══██╗╚██╗ ██╔╝██╔══╝  ██╔══██╗"
    echo "     ██║   ███████╗███████╗███████╗███████╗███████║███████╗██║  ██║ ╚████╔╝ ███████╗██║  ██║"
    echo "     ╚═╝   ╚══════╝╚══════╝╚══════╝╚══════╝╚══════╝╚══════╝╚═╝  ╚═╝  ╚═══╝  ╚══════╝╚═╝  ╚═╝"
    echo -e "${NC}"
    echo -e "  ${DIM}  Telegram File Manager Bot  |  ${CYAN}${GITHUB_URL}${NC}"
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
    "$@" > /tmp/ts_out 2>&1 &
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
import os
import asyncio
import time
import hashlib
import secrets
import string
import subprocess
import aiohttp
from pathlib import Path
from datetime import datetime, timedelta
from dotenv import load_dotenv
from pyrogram import Client, filters
from pyrogram.types import Message, InlineKeyboardMarkup, InlineKeyboardButton

load_dotenv()

API_ID = int(os.getenv("API_ID"))
API_HASH = os.getenv("API_HASH")
BOT_TOKEN = os.getenv("BOT_TOKEN")
ALLOWED_USERS = [int(x) for x in os.getenv("ALLOWED_USERS", "").split(",")]
DOWNLOAD_DIR = Path(os.getenv("DOWNLOAD_DIR", "/opt/tele2server/downloads"))
FILE_EXPIRE_HOURS = int(os.getenv("FILE_EXPIRE_HOURS", "12"))

DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)

app = Client("tele2server", api_id=API_ID, api_hash=API_HASH, bot_token=BOT_TOKEN)

pending_files: dict[int, dict] = {}
active_downloads: dict[int, dict] = {}

def allowed(_, __, message: Message):
    return message.from_user and message.from_user.id in ALLOWED_USERS

allowed_filter = filters.create(allowed)

def make_file_id(name: str) -> str:
    raw = f"{name}{time.time()}"
    return hashlib.md5(raw.encode()).hexdigest()[:16]

def pretty_size(size: float) -> str:
    for unit in ["B", "KB", "MB", "GB"]:
        if size < 1024:
            return f"{size:.2f} {unit}"
        size /= 1024
    return f"{size:.2f} GB"

def eta_text(seconds) -> str:
    if not seconds or seconds <= 0:
        return "unknown"
    seconds = int(seconds)
    h = seconds // 3600
    m = (seconds % 3600) // 60
    s = seconds % 60
    if h:
        return f"{h}h {m}m {s}s"
    if m:
        return f"{m}m {s}s"
    return f"{s}s"

def progress_bar(percent: float, length: int = 12) -> str:
    filled = int(length * percent / 100)
    bar = "█" * filled + "░" * (length - filled)
    return f"[{bar}]"

def generate_password(length: int = 16) -> str:
    chars = string.ascii_letters + string.digits + "!@#$%^&*"
    return ''.join(secrets.choice(chars) for _ in range(length))

def calc_parts(size_bytes: int, part_mb: int) -> int:
    part = part_mb * 1024 * 1024
    return max(1, -(-size_bytes // part))

def create_rar_parts(source_path: Path, out_dir: Path, base_name: str, password: str, part_mb: int) -> list[Path]:
    out_base = out_dir / base_name
    subprocess.run(
        ["rar", "a", "-m0", f"-p{password}", "-hp", f"-v{part_mb}m", "-ep",
         f"{out_base}.rar", str(source_path)],
        capture_output=True, text=True
    )
    parts = sorted(out_dir.glob(f"{base_name}.part*.rar"))
    if not parts:
        single = out_dir / f"{base_name}.rar"
        if single.exists():
            return [single]
    return parts

def is_direct_url(text: str) -> bool:
    return text.startswith("http://") or text.startswith("https://")

async def get_url_info(url: str) -> tuple[int, str]:
    try:
        async with aiohttp.ClientSession() as session:
            async with session.head(url, allow_redirects=True, timeout=aiohttp.ClientTimeout(total=15)) as resp:
                size = int(resp.headers.get("Content-Length", 0))
                cd = resp.headers.get("Content-Disposition", "")
                fname = ""
                if "filename=" in cd:
                    fname = cd.split("filename=")[-1].strip().strip('"')
                if not fname:
                    fname = str(resp.url).split("/")[-1].split("?")[0]
                return size, fname
    except Exception:
        return 0, ""

async def download_from_url(url: str, save_path: Path, status_msg, user_id: int) -> tuple[bool, str]:
    try:
        async with aiohttp.ClientSession() as session:
            async with session.get(url, allow_redirects=True, timeout=aiohttp.ClientTimeout(total=3600)) as resp:
                if resp.status != 200:
                    return False, f"HTTP {resp.status}"
                total = int(resp.headers.get("Content-Length", 0))
                downloaded = 0
                start_time = time.time()
                last_update = 0
                with open(save_path, 'wb') as f:
                    async for chunk in resp.content.iter_chunked(1024 * 64):
                        if active_downloads.get(user_id, {}).get("cancelled"):
                            return False, "cancelled"
                        f.write(chunk)
                        downloaded += len(chunk)
                        now = time.time()
                        if now - last_update >= 2:
                            last_update = now
                            elapsed = max(now - start_time, 0.1)
                            speed = downloaded / elapsed
                            percent = (downloaded * 100 / total) if total else 0
                            remaining = ((total - downloaded) / speed) if (total and speed) else 0
                            active_downloads[user_id].update({"downloaded": downloaded, "percent": percent})
                            try:
                                await status_msg.edit(
                                    f"📥 **Downloading from URL...**\n\n"
                                    f"📊 Progress: `{percent:.1f}%`\n"
                                    f"⬇️ Size: `{pretty_size(downloaded)}`"
                                    + (f" of `{pretty_size(total)}`" if total else "") + "\n"
                                    f"⚡ Speed: `{pretty_size(speed)}/s`\n"
                                    f"⏱ ETA: `{eta_text(remaining)}`\n\n"
                                    f"{progress_bar(percent)}",
                                    reply_markup=InlineKeyboardMarkup([[
                                        InlineKeyboardButton("❌ Cancel", callback_data=f"cancel_dl_{user_id}")
                                    ]])
                                )
                            except Exception:
                                pass
        return True, ""
    except Exception as e:
        return False, str(e)

async def process_file(client, chat_id, status_msg, user_id, file_name, file_size, save_path):
    await status_msg.edit(
        f"🗜 **Archiving into 20MB parts...**\n\n"
        f"📄 File: `{file_name}`\n⏳ Please wait..."
    )
    try:
        base_name = make_file_id(file_name)
        password = generate_password()
        loop = asyncio.get_event_loop()
        parts = await loop.run_in_executor(
            None, create_rar_parts, save_path, DOWNLOAD_DIR, base_name, password, 20
        )
        save_path.unlink(missing_ok=True)
    except Exception as e:
        await status_msg.edit(f"❌ Archive error:\n`{e}`")
        return

    if not parts:
        await status_msg.edit("❌ Failed to create archive.")
        return

    await status_msg.edit(
        f"📤 **Sending {len(parts)} parts to Telegram...**\n\n"
        f"📄 File: `{file_name}`\n⏳ Please wait..."
    )

    all_sent = True
    for i, part in enumerate(parts, 1):
        try:
            await client.send_document(
                chat_id=chat_id,
                document=str(part),
                caption=f"📦 Part {i} of {len(parts)} — `{file_name}`",
                force_document=True
            )
        except Exception as e:
            await client.send_message(chat_id, f"❌ Error sending part {i}:\n`{e}`")
            all_sent = False
        finally:
            part.unlink(missing_ok=True)

    msg = (
        f"✅ **All parts sent!**\n\n"
        f"📄 Original: `{file_name}`\n"
        f"📦 Parts: `{len(parts)}`\n\n"
        f"🔑 **Password:**\n`{password}`\n\n"
        f"📌 Download all parts, place them together, open `part1.rar` with WinRAR or ZArchiver."
    ) if all_sent else (
        f"⚠️ Some parts failed to send.\n\n🔑 **Password:**\n`{password}`"
    )
    await client.send_message(chat_id, msg)

def make_keyboard(user_id: int) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup([
        [InlineKeyboardButton("🗜 RAR 20MB Parts", callback_data=f"upload_rar20_{user_id}")],
    ])

@app.on_message(filters.command("start") & allowed_filter)
async def start(client, message: Message):
    await message.reply(
        "👋 **Hello!**\n\n"
        "Send me a file or direct URL.\n"
        "I'll compress it into password-protected 20MB RAR parts and send them back.\n\n"
        "📋 `/queue` — active downloads\n"
        "❌ `/cancel` — cancel current download"
    )

@app.on_message(filters.command("queue") & allowed_filter)
async def queue_status(client, message: Message):
    if not active_downloads:
        await message.reply("✅ Queue is empty.")
        return
    text = "📋 **Active Downloads:**\n\n"
    for uid, info in active_downloads.items():
        text += (
            f"🔹 **{info['name']}**\n"
            f"   ⬇️ {pretty_size(info.get('downloaded', 0))} of {pretty_size(info.get('total', 0))}\n"
            f"   📊 {info.get('percent', 0):.1f}%\n\n"
        )
    await message.reply(text)

@app.on_message(filters.command("cancel") & allowed_filter)
async def cancel_download(client, message: Message):
    user_id = message.from_user.id
    if user_id in active_downloads:
        active_downloads[user_id]["cancelled"] = True
        await message.reply("❌ Download cancelled.")
    else:
        await message.reply("No active download found.")

@app.on_message(filters.text & allowed_filter & ~filters.command(["start", "queue", "cancel"]))
async def handle_url(client: Client, message: Message):
    url = message.text.strip()
    if not is_direct_url(url):
        return
    user_id = message.from_user.id
    checking_msg = await message.reply("🔍 Checking URL...")
    size, fname = await get_url_info(url)
    if not fname or len(fname) < 3:
        fname = url.split("/")[-1].split("?")[0] or f"file_{int(time.time())}"
    size_text = pretty_size(size) if size else "Unknown"
    parts20 = calc_parts(size, 20) if size else "?"
    pending_files[user_id] = {"type": "url", "url": url, "file_name": fname, "file_size": size}
    await checking_msg.edit(
        f"🔗 **URL received**\n\n"
        f"📄 File: `{fname}`\n"
        f"📦 Size: `{size_text}`\n"
        f"🗂 Parts (20MB): `{parts20}`\n\n"
        "Ready to compress and send?",
        reply_markup=make_keyboard(user_id)
    )

@app.on_message(
    allowed_filter &
    (filters.document | filters.video | filters.audio | filters.photo)
)
async def handle_file(client: Client, message: Message):
    user_id = message.from_user.id
    if message.document:
        file = message.document
        file_name = file.file_name or f"file_{int(time.time())}"
        file_size = file.file_size
    elif message.video:
        file = message.video
        file_name = f"video_{int(time.time())}.mp4"
        file_size = file.file_size
    elif message.audio:
        file = message.audio
        file_name = file.file_name or f"audio_{int(time.time())}.mp3"
        file_size = file.file_size
    elif message.photo:
        file = message.photo
        file_name = f"photo_{int(time.time())}.jpg"
        file_size = file.file_size
    else:
        return
    parts20 = calc_parts(file_size, 20)
    pending_files[user_id] = {"type": "telegram", "message": message, "file_name": file_name, "file_size": file_size}
    await message.reply(
        f"📄 **File received:** `{file_name}`\n"
        f"📦 Size: `{pretty_size(file_size)}`\n"
        f"🗂 Parts (20MB): `{parts20}`\n\n"
        "Ready to compress and send?",
        reply_markup=make_keyboard(user_id)
    )

@app.on_callback_query()
async def handle_callback(client: Client, callback_query):
    data = callback_query.data
    user_id = callback_query.from_user.id

    if data.startswith("cancel_dl_"):
        target_uid = int(data.split("_")[-1])
        if target_uid in active_downloads:
            active_downloads[target_uid]["cancelled"] = True
            await callback_query.answer("❌ Cancel requested.")
        else:
            await callback_query.answer("No active download.", show_alert=True)
        return

    if not data.startswith("upload_rar20_"):
        return

    if user_id not in pending_files:
        await callback_query.answer("⚠️ File expired, please send again.", show_alert=True)
        return

    info = pending_files.pop(user_id)
    file_name = info["file_name"]
    chat_id = callback_query.message.chat.id

    await callback_query.message.edit_reply_markup(reply_markup=None)
    await callback_query.answer()

    file_id_short = make_file_id(file_name)
    safe_name = f"{file_id_short}_{file_name}"
    save_path = DOWNLOAD_DIR / safe_name

    active_downloads[user_id] = {
        "name": file_name, "total": info.get("file_size", 0),
        "downloaded": 0, "percent": 0, "cancelled": False,
    }

    cancel_btn = InlineKeyboardMarkup([[
        InlineKeyboardButton("❌ Cancel", callback_data=f"cancel_dl_{user_id}")
    ]])

    if info["type"] == "url":
        status_msg = await callback_query.message.reply(
            f"📥 **Downloading from URL...**\n\n🔗 `{info['url']}`\n\n{progress_bar(0)} 0%",
            reply_markup=cancel_btn
        )
        ok, err = await download_from_url(info["url"], save_path, status_msg, user_id)
        if not ok:
            active_downloads.pop(user_id, None)
            save_path.unlink(missing_ok=True)
            await status_msg.edit("❌ Download cancelled." if err == "cancelled" else f"❌ Error:\n`{err}`", reply_markup=None)
            return
        file_size = save_path.stat().st_size
        active_downloads.pop(user_id, None)
        await status_msg.edit_reply_markup(reply_markup=None)
        await process_file(client, chat_id, status_msg, user_id, file_name, file_size, save_path)

    else:
        message = info["message"]
        file_size = info["file_size"]
        status_msg = await callback_query.message.reply(
            f"📥 **Downloading from Telegram...**\n\n"
            f"📄 File: `{file_name}`\n"
            f"📦 Size: `{pretty_size(file_size)}`\n\n"
            f"{progress_bar(0)} 0%",
            reply_markup=cancel_btn
        )
        start_time = time.time()
        last_update = [0]

        async def progress(current, total):
            if active_downloads.get(user_id, {}).get("cancelled"):
                return
            now = time.time()
            if now - last_update[0] < 2 and current < total:
                return
            last_update[0] = now
            elapsed = max(now - start_time, 0.1)
            speed = current / elapsed
            remaining = (total - current) / speed if speed > 0 else 0
            percent = current * 100 / total if total else 0
            active_downloads[user_id].update({"downloaded": current, "percent": percent})
            try:
                await status_msg.edit(
                    f"📥 **Downloading from Telegram...**\n\n"
                    f"📄 File: `{file_name}`\n"
                    f"📊 Progress: `{percent:.1f}%`\n"
                    f"⬇️ Size: `{pretty_size(current)}` of `{pretty_size(total)}`\n"
                    f"⚡ Speed: `{pretty_size(speed)}/s`\n"
                    f"⏱ ETA: `{eta_text(remaining)}`\n\n"
                    f"{progress_bar(percent)}",
                    reply_markup=cancel_btn
                )
            except Exception:
                pass

        try:
            await client.download_media(message, file_name=str(save_path), progress=progress)
        except Exception as e:
            active_downloads.pop(user_id, None)
            await status_msg.edit(f"❌ Download error:\n`{e}`", reply_markup=None)
            return

        if active_downloads.get(user_id, {}).get("cancelled"):
            active_downloads.pop(user_id, None)
            save_path.unlink(missing_ok=True)
            await status_msg.edit("❌ Download cancelled.", reply_markup=None)
            return

        active_downloads.pop(user_id, None)
        await status_msg.edit_reply_markup(reply_markup=None)
        await process_file(client, chat_id, status_msg, user_id, file_name, file_size, save_path)

async def cleanup_loop():
    while True:
        await asyncio.sleep(600)
        now = time.time()
        expire_seconds = FILE_EXPIRE_HOURS * 3600
        for f in DOWNLOAD_DIR.iterdir():
            if f.is_file():
                age = now - f.stat().st_mtime
                if age > expire_seconds:
                    try:
                        f.unlink()
                    except Exception:
                        pass

async def main():
    async with app:
        await asyncio.gather(
            asyncio.Event().wait(),
            cleanup_loop(),
        )

if __name__ == "__main__":
    app.run(main())
BOTEOF
}

# ── Install ───────────────────────────────────────────────────
do_install() {
    print_banner
    echo -e "  ${BOLD}Setup — Enter your credentials${NC}"
    divider
    echo ""
    echo -e "  ${DIM}You need these before continuing:${NC}"
    echo -e "  ${DIM}• API_ID & API_HASH from ${CYAN}my.telegram.org${NC}"
    echo -e "  ${DIM}• Bot Token from ${CYAN}@BotFather${NC}"
    echo -e "  ${DIM}• Your numeric user ID from ${CYAN}@myidbot${NC}"
    echo ""
    divider

    ask "Telegram API_ID   :" API_ID
    while ! [[ "$API_ID" =~ ^[0-9]+$ ]]; do
        print_warn "API_ID must be a number."
        ask "Telegram API_ID   :" API_ID
    done

    ask "Telegram API_HASH :" API_HASH
    while [ ${#API_HASH} -lt 10 ]; do
        print_warn "API_HASH looks too short."
        ask "Telegram API_HASH :" API_HASH
    done

    ask "Bot Token         :" BOT_TOKEN
    while ! [[ "$BOT_TOKEN" =~ ^[0-9]+: ]]; do
        print_warn "Invalid token format. Should be like: 123456789:AAF..."
        ask "Bot Token         :" BOT_TOKEN
    done

    ask "Allowed User IDs  :" ALLOWED_USERS
    while [ -z "$ALLOWED_USERS" ]; do
        print_warn "At least one user ID is required."
        ask "Allowed User IDs  :" ALLOWED_USERS
    done

    echo ""
    divider
    echo -e "  ${BOLD}Review:${NC}"
    thin_divider
    echo -e "  API_ID       : ${YELLOW}${API_ID}${NC}"
    echo -e "  API_HASH     : ${DIM}${API_HASH:0:8}...${NC}"
    echo -e "  Bot Token    : ${DIM}${BOT_TOKEN:0:20}...${NC}"
    echo -e "  User IDs     : ${YELLOW}${ALLOWED_USERS}${NC}"
    echo -e "  Install path : ${DIM}${INSTALL_DIR}${NC}"
    divider

    confirm "Proceed with installation?" || { echo ""; print_warn "Cancelled."; exit 0; }

    echo ""
    print_step "1" "Updating system"
    run_silent "Refreshing package lists       " apt-get update -qq
    run_silent "Upgrading packages             " apt-get upgrade -y -qq

    print_step "2" "Installing dependencies"
    run_silent "Installing system packages      " apt-get install -y -qq python3 python3-venv python3-pip python3-dev gcc curl rar unrar



    print_step "3" "Preparing directory"
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        systemctl stop "$SERVICE_NAME" 2>/dev/null || true
        systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    fi
    rm -rf "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR/downloads"
    print_ok "Directory ready: ${INSTALL_DIR}"

    print_step "4" "Setting up Python environment"
    run_silent "Creating virtual environment   " python3 -m venv "${INSTALL_DIR}/venv"
    run_silent "Installing Python packages     " "${INSTALL_DIR}/venv/bin/pip" install -q --upgrade pip pyrogram tgcrypto python-dotenv aiofiles aiohttp

    print_step "5" "Writing configuration"
    cat > "${INSTALL_DIR}/.env" << EOF
API_ID=${API_ID}
API_HASH=${API_HASH}
BOT_TOKEN=${BOT_TOKEN}
ALLOWED_USERS=${ALLOWED_USERS}
DOWNLOAD_DIR=${INSTALL_DIR}/downloads
FILE_EXPIRE_HOURS=12
EOF
    chmod 600 "${INSTALL_DIR}/.env"
    print_ok ".env written  (chmod 600)"

    write_bot_py
    print_ok "bot.py written"

    print_step "6" "Registering system service"
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=Tele2Server — Telegram File Manager Bot
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

    print_step "7" "Verifying"
    if svc_active; then
        print_ok "Service is live!"
        echo ""
        echo -e "  ${GREEN}${BOLD}  ╔══════════════════════════════════════════╗"
        echo -e "  ║   Tele2Server installed successfully!    ║"
        echo -e "  ╚══════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "  ${DIM}Send a file or URL to your Telegram bot to test.${NC}"
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
    print_error "Run as root:  sudo bash tele2server.sh"
    exit 1
}

if [[ -f "${INSTALL_DIR}/bot.py" ]]; then
    main_menu
else
    do_install
    main_menu
fi
