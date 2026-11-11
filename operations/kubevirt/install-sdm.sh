#!/bin/bash
# Fresh Oracle Linux guest only. Run as root after copying the vendor media.
set -Eeuo pipefail
umask 077
media=/home/hkl/sdm-media
home=/opt/AcmePacket/NNC90_5
if [ -e "$home" ]; then
    echo 'SDM directory already exists; refusing to overwrite it.' >&2
    exit 1
fi
cd "$media"
sha256sum -c media-sha256.txt
for archive in *_Package.zip; do unzip -tq "$archive"; done
dnf install -y --exclude='oraclelinux-release*' \
    apr apr-util pcre expat libuuid libxcrypt openssl openssl-libs libaio \
    libstdc++ zlib unixODBC libXtst libXi libXrender alsa-lib fontconfig \
    freetype net-tools iproute procps-ng hostname sudo shadow-utils tar gzip \
    unzip which findutils util-linux openssh-clients iputils glibc-langpack-en \
    chrony net-snmp-utils
localectl set-locale LANG=en_US.UTF-8
export LANG=en_US.UTF-8
systemctl enable --now chronyd
systemctl disable --now httpd 2>/dev/null || true
getent group nncentral >/dev/null || groupadd nncentral
id nncentral >/dev/null 2>&1 || useradd -g nncentral -m -s /bin/bash nncentral
admin_password="LabA9!$(openssl rand -hex 16)"
service_password="LabS9!$(openssl rand -hex 16)"
trust_password="LabT9!$(openssl rand -hex 16)"
printf 'nncentral:%s\n' "$service_password" | chpasswd
cat > /root/sdm-setup.properties <<EOF
R226_COMPLIANCE=enabled
ADMIN_PASSWORD=$admin_password
LI_ADMIN_PASSWORD=$admin_password
GLOBAL_CONFIG_ID=SDM-KUBEVIRT-LAB
SERVER_NAME=sdm-kubevirt
TRUST_STORE_PASSWORD=$trust_password
RMI_TRUST_STORE_PASSWORD=$trust_password
SUDO_PASSWORD=$service_password
SFTP_PASSWORD=$service_password
EOF
printf 'SDM web username: admin\nSDM web password: %s\nLinux service username: nncentral\nLinux service password: %s\n' "$admin_password" "$service_password" > /root/sdm-lab-credentials.txt
unset admin_password service_password trust_password
guest_ip=$(hostname -I | awk '{print $1}')
test -n "$guest_ip"
sed -i '/SDM_localhost/d' /etc/hosts
printf '\n%s sdm-kubevirt SDM_localhost\n' "$guest_ip" >> /etc/hosts
tar -xzf "$media/NNC90_5OracleLinux90_64bit.tar.gz" -C /opt
chown -R nncentral:nncentral /opt/AcmePacket
cat > /etc/security/limits.d/90-sdm.conf <<'EOF'
nncentral soft nofile 65536
nncentral hard nofile 65536
EOF
ulimit -n 65536
if systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port=8443/tcp --add-port=162/udp
    firewall-cmd --reload
fi
cd "$home/bin"
./setup.sh --headless /root/sdm-setup.properties
test -f /opt/AcmePacket/setup_config.ini
cat > /etc/systemd/system/sdm.service <<'EOF'
[Unit]
Description=Oracle Communications Session Delivery Manager lab
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=nncentral
Group=nncentral
WorkingDirectory=/opt/AcmePacket/NNC90_5/bin
Environment=LANG=en_US.UTF-8
LimitNOFILE=65536
ExecStart=/opt/AcmePacket/NNC90_5/bin/startnnc.sh --nomonitor
ExecStop=/opt/AcmePacket/NNC90_5/bin/shutdownnnc.sh
TimeoutStartSec=180
TimeoutStopSec=180

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now sdm
touch /root/sdm-install-complete
echo 'SDM installation completed. Credentials are in /root/sdm-lab-credentials.txt.'
