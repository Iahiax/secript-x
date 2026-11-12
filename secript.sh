#!/bin/bash

# التحقق من صلاحيات الجذر (Root)
if [ "$EUID" -ne 0 ]; then
  echo "[-] يرجى تشغيل السكريبت بصلاحيات الجذر (Root)."
  exit 1
fi

echo "[+] بدء إعداد النظام والنفق العكسي (GOST + Cloudflare Tunnel + Watchdog)..."

# 1. تحديث النظام وتثبيت الأدوات اللازمة
apt-get update && apt-get install -y curl wget screen git jq systemd ufw

# 2. تنزيل وتثبيت أحدث إصدار من GOST
GOST_VERSION=$(curl -s "https://api.github.com/repos/go-gost/gost/releases/latest" | jq -r .tag_name | sed 's/v//')
if [ -z "$GOST_VERSION" ]; then
  GOST_VERSION="3.0.0-nightly" # قيمة افتراضية في حال الفشل
fi
echo "[+] جاري تحميل GOST الإصدار: $GOST_VERSION"
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
  GOST_ARCH="amd64"
elif [ "$ARCH" = "aarch64" ]; then
  GOST_ARCH="arm64"
else
  GOST_ARCH="amd64"
fi

wget -qO gost.tar.gz "https://github.com/go-gost/gost/releases/download/v3.0.0.rc10/gost_3.0.0-rc10_linux_${GOST_ARCH}.tar.gz" || wget -qO gost.tar.gz "https://github.com/go-gost/gost/releases/latest/download/gost_linux_${GOST_ARCH}.tar.gz"
tar -xzf gost.tar.gz gost 2>/dev/null || tar -xzf gost.tar.gz 2>/dev/null
mv gost /usr/local/bin/gost
chmod +x /usr/local/bin/gost
rm -f gost.tar.gz LICENSE README.md

# 3. إنشاء مجلد الإعدادات
mkdir -p /etc/gost /var/log/gost

# 4. إعداد ملف تكوين GOST (مثال: نفق عكسي محلي إلى منفذ البوت أو الخدمة)
cat << 'EOF' > /etc/gost/config.yaml
services:
  - name: service-tunnel
    addr: ":8080"
    handler:
      type: forward
    listener:
      type: tcp
    forwarder:
      nodes:
        - "tcp://127.0.0.1:3000"
EOF

# 5. إنشاء خدمة systemd لـ GOST مع خاصية الحماية والتشغيل التلقائي (Watchdog & Restart)
cat << 'EOF' > /system/systemd/gost.service 2>/dev/null || cat << 'EOF' > /etc/systemd/system/gost.service
[Unit]
Description=GOST Reverse Tunnel Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/gost
ExecStart=/usr/local/bin/gost -C /etc/gost/config.yaml
Restart=always
RestartSec=5s
StandardOutput=append:/var/log/gost/gost.log
StandardError=append:/var/log/gost/gost_error.log

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable gost.service
systemctl restart gost.service

# 6. إنشاء سكريبت الـ Heartbeat والمراقبة (Watchdog)
cat << 'EOF' > /usr/local/bin/system_heartbeat.sh
#!/bin/bash
# إعدادات Healthchecks.io أو خادم المراقبة الخاص بك
HEALTH_CHECK_URL="https://hc-ping.com/YOUR-UUID-HERE"

while true; do
  # التحقق من أن خدمة GOST تعمل
  if ! systemctl is-active --quiet gost.service; then
    echo "$(date): GOST متوقف! جاري إعادة التشغيل..." >> /var/log/gost/watchdog.log
    systemctl restart gost.service
  fi

  # إرسال نبضة نبض القلب (Heartbeat)
  if [ -n "$HEALTH_CHECK_URL" ] && [ "$HEALTH_CHECK_URL" != "https://hc-ping.com/YOUR-UUID-HERE" ]; then
    curl -fsS -m 10 --retry 3 "$HEALTH_CHECK_URL" > /dev/null 2>&1
  fi

  # فحص البوت العامل داخل جلسة Screen (مثال: بوت باسم "mybot")
  if ! screen -list | grep -q "mybot"; then
    echo "$(date): جلسة Screen للبوت غير موجودة، جاري إعادة تشغيل البوت..." >> /var/log/gost/watchdog.log
    # يمكنك وضع أمر تشغيل البوت الخاص بك هنا
    # screen -dmS mybot python3 /path/to/bot.py
  fi

  sleep 60
done
EOF

chmod +x /usr/local/bin/system_heartbeat.sh

# 7. إنشاء خدمة systemd للـ Watchdog والـ Heartbeat الداخلي
cat << 'EOF' > /etc/systemd/system/system-watchdog.service
[Unit]
Description=System Heartbeat & Watchdog Monitor
After=network.target gost.service

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/system_heartbeat.sh
Restart=always
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable system-watchdog.service
systemctl start system-watchdog.service

echo "[+] تم تثبيت وإعداد البنية بنجاح!"
echo "[*] يمكنك فحص حالة GOST عبر: systemctl status gost"
echo "[*] يمكنك فحص حالة المراقبة عبر: systemctl status system-watchdog"
