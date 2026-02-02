#!/bin/bash

# --- 1. 环境清理 ---
echo "正在清理旧环境..."
cd /root/manga_bot 2>/dev/null
docker-compose down --rmi all 2>/dev/null
pkill -f bot_writer.py 2>/dev/null
pkill -f auto_scraper.py 2>/dev/null

# --- 2. 全交互配置 ---
echo "--- 漫画下载机器人 全交互部署脚本 ---"

# 交互输入 Token
READ_TOKEN=""
while [ -z "$READ_TOKEN" ]; do
    read -p "请输入你的 Telegram Bot Token: " READ_TOKEN
done

# 交互输入 User ID
READ_ID=""
while [ -z "$READ_ID" ]; do
    read -p "请输入你的 Telegram User ID: " READ_ID
done

# 交互输入下载路径 (提供默认值)
DEFAULT_DIR="/root/docker/manhua/comics"
read -p "请输入下载保存路径 (直接回车使用默认值 $DEFAULT_DIR): " READ_DIR
DOWNLOAD_DIR=${READ_DIR:-$DEFAULT_DIR}

PROJECT_DIR="/root/manga_bot"

echo "正在准备目录..."
mkdir -p $PROJECT_DIR
mkdir -p $DOWNLOAD_DIR
cd $PROJECT_DIR

# --- 3. 机器人脚本 (bot_writer.py) ---
cat <<EOF > bot_writer.py
import os, asyncio
from telegram import Update
from telegram.ext import Application, MessageHandler, filters, ContextTypes

TOKEN = "$READ_TOKEN"
MY_ID = $READ_ID
WEB_TXT_PATH = "web.txt"
FINISH_TXT = "finish.txt"
# 这里的路径会根据你输入的内容动态生成
DISPLAY_PATH = "$DOWNLOAD_DIR"

async def handle_link(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if update.effective_user.id != MY_ID: return
    url = update.message.text.strip()
    if url.startswith("http"):
        with open(WEB_TXT_PATH, "a", encoding="utf-8") as f:
            f.write(f"{url}\n")
        await update.message.reply_text("✅ 任务已排队，完成后我会通知。")

async def check_finish(context: ContextTypes.DEFAULT_TYPE):
    if os.path.exists(FINISH_TXT) and os.path.getsize(FINISH_TXT) > 0:
        with open(FINISH_TXT, "r", encoding="utf-8") as f:
            titles = f.readlines()
        open(FINISH_TXT, "w").close()
        for title in titles:
            t = title.strip()
            if t:
                msg = f"🎁 下载成功！\n\n【{t}】\n\n📂 存档位置：\n{DISPLAY_PATH}/{t}.cbz"
                await context.bot.send_message(chat_id=MY_ID, text=msg)

if __name__ == "__main__":
    app = Application.builder().token(TOKEN).build()
    app.add_handler(MessageHandler(filters.TEXT & (~filters.COMMAND), handle_link))
    if app.job_queue:
        app.job_queue.run_repeating(check_finish, interval=30, first=10)
    print("🤖 机器人已启动...")
    app.run_polling()
EOF

# --- 4. 爬虫脚本 (auto_scraper.py) ---
cat <<EOF > auto_scraper.py
import os, shutil, requests, random, time, zipfile, urllib3, io
from urllib.parse import urljoin
from bs4 import BeautifulSoup
from PIL import Image
from concurrent.futures import ThreadPoolExecutor, as_completed

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

WEB_TXT_PATH = "web.txt"
FINISH_TXT = "finish.txt"
DEST_DIR = "/downloads"

def down_img(url, idx, temp_dir):
    try:
        h = {"User-Agent": "Mozilla/5.0"}
        r = requests.get(url, headers=h, timeout=15, verify=False)
        if r.status_code != 200: return None
        jpg_path = os.path.join(temp_dir, f"{idx:03d}.jpg")
        with Image.open(io.BytesIO(r.content)) as im:
            im.convert('RGB').save(jpg_path, 'JPEG', quality=95)
        return jpg_path
    except: return None

def process_url(url):
    tid = int(time.time())
    tmp_d = f"tmp_{tid}"
    os.makedirs(tmp_d, exist_ok=True)
    try:
        h = {"User-Agent": "Mozilla/5.0"}
        r = requests.get(url, headers=h, timeout=15, verify=False)
        r.encoding = r.apparent_encoding
        soup = BeautifulSoup(r.text, 'html.parser')
        title = (soup.title.string if soup.title else f"manga_{tid}").strip()
        for c in '/\\\\:*?"<>| ': title = title.replace(c, '_')
        
        img_urls = []
        for img in soup.find_all('img'):
            src = img.get('data-original') or img.get('data-src') or img.get('src')
            if src and not src.startswith('data:'): img_urls.append(urljoin(url, src))
        img_urls = list(dict.fromkeys(img_urls))

        if not img_urls: return False

        print(f"\n🚀 开始处理: {title}")
        jpgs = []
        with ThreadPoolExecutor(max_workers=10) as exe:
            futures = [exe.submit(down_img, u, i, tmp_d) for i, u in enumerate(img_urls)]
            count = 0
            for f in as_completed(futures):
                count += 1
                if f.result(): jpgs.append(f.result())
                if count % 5 == 0 or count == len(img_urls):
                    print(f"   进度: [{count}/{len(img_urls)}]")

        if jpgs:
            cbz = f"{title}.cbz"
            with zipfile.ZipFile(cbz, 'w') as z:
                for f in sorted(jpgs): z.write(f, os.path.basename(f))
            shutil.move(cbz, os.path.join(DEST_DIR, cbz))
            with open(FINISH_TXT, "a", encoding="utf-8") as f:
                f.write(f"{title}\n")
            print(f"✅ 完成: {cbz}")
            return True
        return False
    except Exception as e:
        print(f"💥 异常: {e}")
        return False
    finally:
        if os.path.exists(tmp_d): shutil.rmtree(tmp_d)

def main():
    while True:
        if not os.path.exists(WEB_TXT_PATH) or os.path.getsize(WEB_TXT_PATH) == 0:
            time.sleep(10); continue
        with open(WEB_TXT_PATH, 'r', encoding='utf-8') as f: lines = f.readlines()
        url = lines[0].strip()
        if url: process_url(url)
        with open(WEB_TXT_PATH, 'w', encoding='utf-8') as f: f.writelines(lines[1:])

if __name__ == "__main__":
    main()
EOF

# --- 5. Docker 配置 ---
echo "python-telegram-bot[job-queue]" > requirements.txt
echo "requests" >> requirements.txt
echo "beautifulsoup4" >> requirements.txt
echo "Pillow" >> requirements.txt

cat <<EOF > Dockerfile
FROM python:3.10-slim
RUN apt-get update && apt-get install -y libjpeg-dev zlib1g-dev && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
CMD ["sh", "-c", "python3 bot_writer.py & python3 auto_scraper.py"]
EOF

cat <<EOF > docker-compose.yml
version: '3.8'
services:
  manga-bot:
    build: .
    container_name: manga_bot_container
    restart: always
    volumes:
      - $DOWNLOAD_DIR:/downloads
      - .:/app
    environment:
      - TZ=Asia/Shanghai
      - PYTHONUNBUFFERED=1
EOF

# --- 6. 启动 ---
touch web.txt finish.txt
docker-compose up -d --build

echo "------------------------------------------------"
echo "✨ 部署成功！"
echo "📂 保存目录：$DOWNLOAD_DIR"
echo "📊 实时日志：docker logs -f manga_bot_container"
echo "------------------------------------------------"
