#!/bin/bash

# التحقق من صلاحيات الجذر (Root)
if [ "$EUID" -ne 0 ]; then
  echo "[-] يرجى تشغيل السكريبت بصلاحيات الجذر (Root)."
  exit 1
fi

echo "[+] بدء إعداد النظام، النفق العكسي، وسطح المكتب البعيد (xRDP + GOST + Watchdog)..."

# 1. تحديث النظام وتثبيت الأدوات الأساسية
apt-get update && apt-get install -y curl wget screen git jq systemd ufw

# 2. تثبيت واجهة سطح المكتب الخفيفة (XFCE) وخدمة xRDP للاتصال البعيد
echo "[+] جاري تثبيت واجهة XFCE وخدمة xRDP..."
DEBIAN_FRONTEND=noninteractive apt-get install -y xfce4 xfce4-goodies xrdp

# إعداد xRDP لاستخدام واجهة XFCE
echo "startxfce4" > ~/.xsession
sed -i '/x-session-manager/s/^/#/' /etc/xrdp/startwm.sh 2>/dev/null
echo "startxfce4" >> /etc/xrdp/startwm.sh

# تفعيل وتشغيل xRDP
systemctl enable xrdp
systemctl restart xrdp

# 3. إنشاء أو استخراج بيانات الدخول الخاصة بالريموت ديسكتوب
REMOTE_USER="root"
# إذا كنت ترغب بإنشاء مستخدم جديد مخصص للريموت، يمكنك تفعيل الأسطر التالية:
# REMOTE_USER="remote_user"
# id "$REMOTE_USER" &>/dev/null || useradd -m -s /bin/bash "$REMOTE_USER"
# echo "$REMOTE_USER:StrongPassword123" | chpasswd

SERVER_IP=$(curl -s ifconfig.me || hostname -I | awk '{print $1}')
XRDP_PORT=3389

# حفظ بيانات الدخول في ملف خاص للرجوع إليها
mkdir -p /etc/gost/credentials
cat << EOF > /etc/gost/credentials/xrdp_access.txt
========================================
 بيانات الدخول لسطح المكتب البعيد (xRDP)
========================================
- عنوان السيرفر (IP): $SERVER_IP
- اسم المستخدم: $REMOTE_USER
- كلمة المرور: (كلمة مرور نظام الجذر أو المستخدم الحالي)
- منفذ الاتصال (Port): $XRDP_PORT
========================================
EOF

echo "[+] تم حفظ بيانات الدخول في: /etc/gost/credentials/xrdp_access.txt"

# 4. تنزيل وتثبيت أحدث إصدار من GOST
GOST_VERSION=$(curl -s "https://api.github.com/repos/go-gost/gost/releases/latest" | jq -r .tag_name | sed 's/v//')
if [ -z "$GOST_VERSION" ]; then
  GOST_VERSION="3.0.0-nightly"
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

# 5. إعداد ملف تكوين GOST (توجيه النفق إذا لزم الأمر، مثلاً لتأمين منفذ xRDP أو خدمة أخرى)
mkdir -p /etc/gost /var/log/gost
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
        - "tcp://127.0.0.1:3389"
EOF

# 6. إنشاء خدمة systemd لـ GOST
cat << 'EOF' > /etc/systemd/system/gost.service
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

# 7. إنشاء سكريبت الـ Heartbeat والمراقبة (Watchdog)
cat << 'EOF' > /usr/local/bin/system_heartbeat.sh
#!/bin/bash
HEALTH_CHECK_URL="https://hc-ping.com/YOUR-UUID-HERE"

while true; do
  # التحقق من عمل GOST
  if ! systemctl is-active --quiet gost.service; then
    systemctl restart gost.service
  fi

  # التحقق من عمل xRDP
  if ! systemctl is-active --quiet xrdp; then
    systemctl restart xrdp
  fi

  # إرسال نبضة القلب (Heartbeat)
  if [ -n "$HEALTH_CHECK_URL" ] && [ "$HEALTH_CHECK_URL" != "https://hc-ping.com/YOUR-UUID-HERE" ]; then
    curl -fsS -m 10 --retry 3 "$HEALTH_CHECK_URL" > /dev/null 2>&1
  fi

  sleep 60
done
EOF

chmod +x /usr/local/bin/system_heartbeat.sh

# 8. إعداد خدمة المراقبة systemd
cat << 'EOF' > /etc/systemd/system/system-watchdog.service
[Unit]
Description=System Heartbeat & Watchdog Monitor
After=network.target gost.service xrdp.service

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

echo "[+] تم اكتمال التثبيت بنجاح!"
echo "----------------------------------------"
cat /etc/gost/credentials/xrdp_access.txt
echo "----------------------------------------"
