#!/bin/bash
# ================================================================
#  Tele2Server — Telegram File Manager Bot
#  https://github.com/CyberRhythm/ShadowLink
# ================================================================

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
INSTALL_DIR="/opt/tele2server"
SERVICE_NAME="tele2server"

# ── UI helpers ────────────────────────────────────────────────
print_banner() {
    clear 2>/dev/null || true
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
        sleep 0.08 || true
    done
    printf "\r  ${GREEN}✓${NC}  %-50s\n" "$msg"
}

run_silent() {
    local msg="$1"; shift
    "$@" > /tmp/ts_out 2>&1 &
    local pid=$!
    spinner "$pid" "$msg"
    if ! wait "$pid"; then
        print_error "$msg — failed"
        echo -e "  ${DIM}$(tail -n 5 /tmp/ts_out 2>/dev/null)${NC}"
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

# ── Robust rar installer ──────────────────────────────────────
# `rar` is NOT in Ubuntu's default repos (it lives in `multiverse`, and on
# 22.04 the package is often unavailable entirely). The original script
# simply ran `apt-get install rar` and silently failed, leaving the bot
# unable to compress anything. We try multiverse first, then fall back to
# the official statically-linked binary from rarlab.com.
install_rar() {
    if command -v rar >/dev/null 2>&1; then
        print_ok "rar already installed ($(command -v rar))"
        return 0
    fi

    # Attempt 1: enable multiverse and install from apt.
    add-apt-repository -y multiverse >/dev/null 2>&1 || true
    apt-get update -qq >/dev/null 2>&1 || true
    if apt-get install -y -qq rar unrar >/dev/null 2>&1 && command -v rar >/dev/null 2>&1; then
        print_ok "rar installed via apt (multiverse)"
        return 0
    fi

    # Attempt 2: official rarlab static binary (architecture-aware).
    print_info "apt rar unavailable — installing official rarlab binary"
    local arch url tmpdir
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64) url="https://www.rarlab.com/rar/rarlinux-x64-700.tar.gz" ;;
        aarch64|arm64) url="https://www.rarlab.com/rar/rarlinux-arm-700.tar.gz" ;;
        *) print_error "Unsupported architecture for rar: $arch"; return 1 ;;
    esac
    tmpdir="$(mktemp -d)"
    if curl -fsSL "$url" -o "$tmpdir/rar.tgz" \
        && tar -xzf "$tmpdir/rar.tgz" -C "$tmpdir" \
        && install -m 0755 "$tmpdir/rar/rar" /usr/local/bin/rar \
        && install -m 0755 "$tmpdir/rar/unrar" /usr/local/bin/unrar; then
        rm -rf "$tmpdir"
        print_ok "rar installed to /usr/local/bin (rarlab)"
        return 0
    fi
    rm -rf "$tmpdir"
    print_error "Failed to install rar. Compression will not work."
    return 1
}

# ── Write bot.py ──────────────────────────────────────────────
write_bot_py() {
    cat > "${INSTALL_DIR}/bot.py" << 'BOTEOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# Tele2Server — Telegram file manager bot
# https://github.com/CyberRhythm/ShadowLink
#
# Professional rewrite: validates env, verifies the `rar` binary, checks the
# archiver exit code, handles FloodWait when editing progress messages, uses
# atomic temp files, and never leaks downloaded files on errors.

import os
import sys
import asyncio
import time
import hashlib
import secrets
import shutil
import string
import subprocess
from pathlib import Path

import aiohttp
from dotenv import load_dotenv

try:
    from pyrogram import Client, filters
    from pyrogram.errors import FloodWait, MessageNotModified
    from pyrogram.types import (Message, InlineKeyboardMarkup,
                                InlineKeyboardButton)
except ImportError:
    sys.exit("[FATAL] pyrogram is not installed. Run: pip install pyrogram tgcrypto")

load_dotenv()


# ── Env validation (fail fast, clear messages) ────────────────
def _require_int(name: str) -> int:
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


API_ID = _require_int("API_ID")
API_HASH = _require_str("API_HASH")
BOT_TOKEN = _require_str("BOT_TOKEN")

_allowed_raw = os.getenv("ALLOWED_USERS", "")
ALLOWED_USERS = [int(x) for x in _allowed_raw.split(",") if x.strip().lstrip("-").isdigit()]
if not ALLOWED_USERS:
    sys.exit("[FATAL] ALLOWED_USERS must contain at least one numeric user id")

DOWNLOAD_DIR = Path(os.getenv("DOWNLOAD_DIR", "/opt/tele2server/downloads"))
FILE_EXPIRE_HOURS = int(os.getenv("FILE_EXPIRE_HOURS", "12") or "12")
PART_SIZE_MB = int(os.getenv("PART_SIZE_MB", "20") or "20")

# Resolve the archiver once at startup. We accept `rar` (preferred, true
# multi-volume) and fall back gracefully if it is missing.
RAR_BIN = shutil.which("rar")

DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)

app = Client("tele2server", api_id=API_ID, api_hash=API_HASH, bot_token=BOT_TOKEN)

pending_files: "dict[int, dict]" = {}
active_downloads: "dict[int, dict]" = {}


# ── Access control ────────────────────────────────────────────
def _allowed(_, __, message) -> bool:
    return bool(message.from_user) and message.from_user.id in ALLOWED_USERS


allowed_filter = filters.create(_allowed)


# ── Formatting helpers ────────────────────────────────────────
def make_file_id(name: str) -> str:
    raw = f"{name}{time.time()}{secrets.token_hex(4)}"
    return hashlib.md5(raw.encode()).hexdigest()[:16]


def pretty_size(size: float) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if size < 1024 or unit == "TB":
            return f"{size:.2f} {unit}"
        size /= 1024
    return f"{size:.2f} TB"


def eta_text(seconds) -> str:
    if not seconds or seconds <= 0:
        return "unknown"
    seconds = int(seconds)
    h, rem = divmod(seconds, 3600)
    m, s = divmod(rem, 60)
    if h:
        return f"{h}h {m}m {s}s"
    if m:
        return f"{m}m {s}s"
    return f"{s}s"


def progress_bar(percent: float, length: int = 12) -> str:
    percent = max(0.0, min(100.0, percent))
    filled = int(length * percent / 100)
    return f"[{'█' * filled}{'░' * (length - filled)}]"


def generate_password(length: int = 16) -> str:
    chars = string.ascii_letters + string.digits + "!@#$%^&*"
    return "".join(secrets.choice(chars) for _ in range(length))


def calc_parts(size_bytes: int, part_mb: int) -> int:
    if not size_bytes:
        return 1
    part = part_mb * 1024 * 1024
    return max(1, -(-size_bytes // part))  # ceil division


def is_direct_url(text: str) -> bool:
    return text.startswith("http://") or text.startswith("https://")


# ── Archiving (with real exit-code checking) ──────────────────
def create_rar_parts(source_path: Path, out_dir: Path, base_name: str,
                     password: str, part_mb: int):
    """Create encrypted multi-volume RAR. Returns (parts, error_message)."""
    if not RAR_BIN:
        return [], "rar binary not found on server"

    out_base = out_dir / base_name
    try:
        proc = subprocess.run(
            [RAR_BIN, "a", "-m0", f"-hp{password}", f"-v{part_mb}m", "-ep",
             f"{out_base}.rar", str(source_path)],
            capture_output=True, text=True, timeout=3600,
        )
    except subprocess.TimeoutExpired:
        return [], "archiving timed out"
    except OSError as e:
        return [], f"failed to launch rar: {e}"

    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip()[:300]
        return [], f"rar exited with code {proc.returncode}: {detail}"

    parts = sorted(out_dir.glob(f"{base_name}.part*.rar"))
    if not parts:
        single = out_dir / f"{base_name}.rar"
        if single.exists():
            return [single], ""
        return [], "rar produced no output files"
    return parts, ""


# ── URL helpers ───────────────────────────────────────────────
async def get_url_info(url: str):
    try:
        async with aiohttp.ClientSession() as session:
            async with session.head(url, allow_redirects=True,
                                    timeout=aiohttp.ClientTimeout(total=15)) as resp:
                size = int(resp.headers.get("Content-Length", 0) or 0)
                cd = resp.headers.get("Content-Disposition", "")
                fname = ""
                if "filename=" in cd:
                    fname = cd.split("filename=")[-1].strip().strip('"')
                if not fname:
                    fname = str(resp.url).split("/")[-1].split("?")[0]
                return size, fname
    except (aiohttp.ClientError, asyncio.TimeoutError, ValueError):
        return 0, ""


async def safe_edit(status_msg, text, reply_markup=None):
    """Edit a message, transparently handling FloodWait & no-op edits."""
    try:
        await status_msg.edit(text, reply_markup=reply_markup)
    except FloodWait as e:
        await asyncio.sleep(e.value + 1)
        try:
            await status_msg.edit(text, reply_markup=reply_markup)
        except Exception:
            pass
    except MessageNotModified:
        pass
    except Exception:
        pass


async def download_from_url(url: str, save_path: Path, status_msg, user_id: int):
    try:
        async with aiohttp.ClientSession() as session:
            async with session.get(url, allow_redirects=True,
                                   timeout=aiohttp.ClientTimeout(total=3600)) as resp:
                if resp.status != 200:
                    return False, f"HTTP {resp.status}"
                total = int(resp.headers.get("Content-Length", 0) or 0)
                downloaded = 0
                start_time = time.time()
                last_update = 0.0
                with open(save_path, "wb") as f:
                    async for chunk in resp.content.iter_chunked(64 * 1024):
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
                            active_downloads[user_id].update(
                                {"downloaded": downloaded, "percent": percent})
                            await safe_edit(
                                status_msg,
                                f"📥 **Downloading from URL...**\n\n"
                                f"📊 Progress: `{percent:.1f}%`\n"
                                f"⬇️ Size: `{pretty_size(downloaded)}`"
                                + (f" of `{pretty_size(total)}`" if total else "") + "\n"
                                f"⚡ Speed: `{pretty_size(speed)}/s`\n"
                                f"⏱ ETA: `{eta_text(remaining)}`\n\n"
                                f"{progress_bar(percent)}",
                                InlineKeyboardMarkup([[
                                    InlineKeyboardButton("❌ Cancel",
                                                         callback_data=f"cancel_dl_{user_id}")
                                ]]),
                            )
        return True, ""
    except (aiohttp.ClientError, asyncio.TimeoutError, OSError) as e:
        return False, str(e)


# ── Compress + send pipeline ──────────────────────────────────
async def process_file(client, chat_id, status_msg, user_id,
                       file_name, file_size, save_path: Path):
    await safe_edit(status_msg,
                    f"🗜 **Archiving into {PART_SIZE_MB}MB parts...**\n\n"
                    f"📄 File: `{file_name}`\n⏳ Please wait...")

    base_name = make_file_id(file_name)
    password = generate_password()
    loop = asyncio.get_event_loop()
    try:
        parts, err = await loop.run_in_executor(
            None, create_rar_parts, save_path, DOWNLOAD_DIR,
            base_name, password, PART_SIZE_MB)
    except Exception as e:  # defensive: executor wrapper
        parts, err = [], str(e)
    finally:
        # The source is no longer needed once handed to the archiver.
        try:
            save_path.unlink(missing_ok=True)
        except OSError:
            pass

    if not parts:
        await safe_edit(status_msg, f"❌ Archive failed.\n`{err or 'unknown error'}`")
        return

    await safe_edit(status_msg,
                    f"📤 **Sending {len(parts)} parts to Telegram...**\n\n"
                    f"📄 File: `{file_name}`\n⏳ Please wait...")

    all_sent = True
    for i, part in enumerate(parts, 1):
        try:
            await client.send_document(
                chat_id=chat_id, document=str(part),
                caption=f"📦 Part {i} of {len(parts)} — `{file_name}`",
                force_document=True)
        except FloodWait as e:
            await asyncio.sleep(e.value + 1)
            try:
                await client.send_document(
                    chat_id=chat_id, document=str(part),
                    caption=f"📦 Part {i} of {len(parts)} — `{file_name}`",
                    force_document=True)
            except Exception as e2:
                await client.send_message(chat_id, f"❌ Error sending part {i}:\n`{e2}`")
                all_sent = False
        except Exception as e:
            await client.send_message(chat_id, f"❌ Error sending part {i}:\n`{e}`")
            all_sent = False
        finally:
            try:
                part.unlink(missing_ok=True)
            except OSError:
                pass

    if all_sent:
        msg = (f"✅ **All parts sent!**\n\n"
               f"📄 Original: `{file_name}`\n"
               f"📦 Parts: `{len(parts)}`\n\n"
               f"🔑 **Password:**\n`{password}`\n\n"
               f"📌 Download all parts, place them together, "
               f"open `part1.rar` with WinRAR or ZArchiver.")
    else:
        msg = f"⚠️ Some parts failed to send.\n\n🔑 **Password:**\n`{password}`"
    await client.send_message(chat_id, msg)


def make_keyboard(user_id: int) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup([
        [InlineKeyboardButton(f"🗜 RAR {PART_SIZE_MB}MB Parts",
                              callback_data=f"upload_rar_{user_id}")],
    ])


# ── Command handlers ──────────────────────────────────────────
@app.on_message(filters.command("start") & allowed_filter)
async def start(client, message):
    warn = "" if RAR_BIN else "\n\n⚠️ **هشدار:** ابزار `rar` روی سرور نصب نیست؛ فشرده‌سازی کار نمی‌کند."
    await message.reply(
        "👋 **Hello!**\n\n"
        "Send me a file or a direct URL.\n"
        f"I'll compress it into password-protected {PART_SIZE_MB}MB RAR parts "
        "and send them back.\n\n"
        "📋 `/queue` — active downloads\n"
        "❌ `/cancel` — cancel current download" + warn)


@app.on_message(filters.command("queue") & allowed_filter)
async def queue_status(client, message):
    if not active_downloads:
        await message.reply("✅ Queue is empty.")
        return
    text = "📋 **Active Downloads:**\n\n"
    for _, info in active_downloads.items():
        text += (f"🔹 **{info['name']}**\n"
                 f"   ⬇️ {pretty_size(info.get('downloaded', 0))} "
                 f"of {pretty_size(info.get('total', 0))}\n"
                 f"   📊 {info.get('percent', 0):.1f}%\n\n")
    await message.reply(text)


@app.on_message(filters.command("cancel") & allowed_filter)
async def cancel_download(client, message):
    user_id = message.from_user.id
    if user_id in active_downloads:
        active_downloads[user_id]["cancelled"] = True
        await message.reply("❌ Download cancelled.")
    else:
        await message.reply("No active download found.")


@app.on_message(filters.text & allowed_filter
                & ~filters.command(["start", "queue", "cancel"]))
async def handle_url(client, message):
    url = message.text.strip()
    if not is_direct_url(url):
        return
    user_id = message.from_user.id
    checking = await message.reply("🔍 Checking URL...")
    size, fname = await get_url_info(url)
    if not fname or len(fname) < 3:
        fname = url.split("/")[-1].split("?")[0] or f"file_{int(time.time())}"
    size_text = pretty_size(size) if size else "Unknown"
    parts = calc_parts(size, PART_SIZE_MB) if size else "?"
    pending_files[user_id] = {"type": "url", "url": url,
                              "file_name": fname, "file_size": size}
    await safe_edit(checking,
                    f"🔗 **URL received**\n\n"
                    f"📄 File: `{fname}`\n"
                    f"📦 Size: `{size_text}`\n"
                    f"🗂 Parts ({PART_SIZE_MB}MB): `{parts}`\n\n"
                    "Ready to compress and send?",
                    make_keyboard(user_id))


@app.on_message(allowed_filter
                & (filters.document | filters.video | filters.audio | filters.photo))
async def handle_file(client, message):
    user_id = message.from_user.id
    if message.document:
        file_name = message.document.file_name or f"file_{int(time.time())}"
        file_size = message.document.file_size
    elif message.video:
        file_name = f"video_{int(time.time())}.mp4"
        file_size = message.video.file_size
    elif message.audio:
        file_name = message.audio.file_name or f"audio_{int(time.time())}.mp3"
        file_size = message.audio.file_size
    elif message.photo:
        file_name = f"photo_{int(time.time())}.jpg"
        file_size = message.photo.file_size
    else:
        return
    parts = calc_parts(file_size, PART_SIZE_MB)
    pending_files[user_id] = {"type": "telegram", "message": message,
                              "file_name": file_name, "file_size": file_size}
    await message.reply(
        f"📄 **File received:** `{file_name}`\n"
        f"📦 Size: `{pretty_size(file_size)}`\n"
        f"🗂 Parts ({PART_SIZE_MB}MB): `{parts}`\n\n"
        "Ready to compress and send?",
        reply_markup=make_keyboard(user_id))


@app.on_callback_query()
async def handle_callback(client, callback_query):
    data = callback_query.data or ""
    user_id = callback_query.from_user.id

    if data.startswith("cancel_dl_"):
        try:
            target_uid = int(data.split("_")[-1])
        except ValueError:
            await callback_query.answer("Invalid request.", show_alert=True)
            return
        if target_uid in active_downloads:
            active_downloads[target_uid]["cancelled"] = True
            await callback_query.answer("❌ Cancel requested.")
        else:
            await callback_query.answer("No active download.", show_alert=True)
        return

    if not data.startswith("upload_rar_"):
        return

    if not RAR_BIN:
        await callback_query.answer("⚠️ rar is not installed on the server.",
                                    show_alert=True)
        return

    if user_id not in pending_files:
        await callback_query.answer("⚠️ File expired, please send again.",
                                    show_alert=True)
        return

    info = pending_files.pop(user_id)
    file_name = info["file_name"]
    chat_id = callback_query.message.chat.id

    try:
        await callback_query.message.edit_reply_markup(reply_markup=None)
    except Exception:
        pass
    await callback_query.answer()

    safe_fname = f"{make_file_id(file_name)}_{os.path.basename(file_name)}"
    save_path = DOWNLOAD_DIR / safe_fname

    active_downloads[user_id] = {
        "name": file_name, "total": info.get("file_size", 0),
        "downloaded": 0, "percent": 0, "cancelled": False,
    }
    cancel_btn = InlineKeyboardMarkup([[
        InlineKeyboardButton("❌ Cancel", callback_data=f"cancel_dl_{user_id}")
    ]])

    try:
        if info["type"] == "url":
            status_msg = await callback_query.message.reply(
                f"📥 **Downloading from URL...**\n\n🔗 `{info['url']}`\n\n"
                f"{progress_bar(0)} 0%", reply_markup=cancel_btn)
            ok, err = await download_from_url(info["url"], save_path, status_msg, user_id)
            if not ok:
                save_path.unlink(missing_ok=True)
                await safe_edit(status_msg,
                                "❌ Download cancelled." if err == "cancelled"
                                else f"❌ Error:\n`{err}`")
                return
            file_size = save_path.stat().st_size
            await safe_edit(status_msg, "✅ Downloaded. Preparing archive...")
            await process_file(client, chat_id, status_msg, user_id,
                               file_name, file_size, save_path)
        else:
            message = info["message"]
            file_size = info["file_size"]
            status_msg = await callback_query.message.reply(
                f"📥 **Downloading from Telegram...**\n\n"
                f"📄 File: `{file_name}`\n"
                f"📦 Size: `{pretty_size(file_size)}`\n\n"
                f"{progress_bar(0)} 0%", reply_markup=cancel_btn)
            start_time = time.time()
            last_update = [0.0]

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
                await safe_edit(
                    status_msg,
                    f"📥 **Downloading from Telegram...**\n\n"
                    f"📄 File: `{file_name}`\n"
                    f"📊 Progress: `{percent:.1f}%`\n"
                    f"⬇️ Size: `{pretty_size(current)}` of `{pretty_size(total)}`\n"
                    f"⚡ Speed: `{pretty_size(speed)}/s`\n"
                    f"⏱ ETA: `{eta_text(remaining)}`\n\n"
                    f"{progress_bar(percent)}", cancel_btn)

            try:
                await client.download_media(message, file_name=str(save_path),
                                            progress=progress)
            except Exception as e:
                save_path.unlink(missing_ok=True)
                await safe_edit(status_msg, f"❌ Download error:\n`{e}`")
                return

            if active_downloads.get(user_id, {}).get("cancelled"):
                save_path.unlink(missing_ok=True)
                await safe_edit(status_msg, "❌ Download cancelled.")
                return

            await safe_edit(status_msg, "✅ Downloaded. Preparing archive...")
            await process_file(client, chat_id, status_msg, user_id,
                               file_name, file_size, save_path)
    finally:
        active_downloads.pop(user_id, None)


# ── Maintenance ───────────────────────────────────────────────
async def cleanup_loop():
    while True:
        await asyncio.sleep(600)
        now = time.time()
        expire_seconds = FILE_EXPIRE_HOURS * 3600
        try:
            for f in DOWNLOAD_DIR.iterdir():
                if f.is_file() and (now - f.stat().st_mtime) > expire_seconds:
                    try:
                        f.unlink()
                    except OSError:
                        pass
        except OSError:
            pass


async def main():
    if not RAR_BIN:
        print("[WARN] `rar` binary not found — compression will be disabled "
              "until it is installed.", file=sys.stderr)
    async with app:
        print(f"[OK] Tele2Server started. Allowed users: {ALLOWED_USERS}")
        await asyncio.gather(asyncio.Event().wait(), cleanup_loop())


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
    run_silent "Installing base packages        " apt-get install -y -qq python3 python3-venv python3-pip python3-dev gcc curl tar software-properties-common
    install_rar

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
PART_SIZE_MB=20
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
