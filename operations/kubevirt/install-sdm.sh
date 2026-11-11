#!/bin/bash
# Fresh Oracle Linux guest only. Run as root after copying the vendor media.
set -Eeuo pipefail
umask 077
media=/home/hkl/sdm-media
sdm_home=/opt/AcmePacket/NNC90_5
if [ -e "$sdm_home" ]; then
    echo 'SDM directory already exists; refusing to overwrite it.' >&2
    exit 1
fi
cd "$media"
hostnamectl set-hostname sdm-kubevirt
printf 'preserve_hostname: true\nssh_deletekeys: false\n' > /etc/cloud/cloud.cfg.d/99-sdm-hostname.cfg
sha256sum -c media-sha256.txt
dnf install -y --exclude='oraclelinux-release*' \
    apr apr-util pcre expat libuuid libxcrypt openssl openssl-libs libaio \
    libstdc++ zlib unixODBC libXtst libXi libXrender alsa-lib fontconfig \
    freetype net-tools iproute procps-ng hostname sudo shadow-utils tar gzip \
    unzip which findutils util-linux openssh-clients iputils glibc-langpack-en \
    chrony net-snmp-utils python3-requests cloud-utils-growpart lvm2 \
    libxslt libglvnd-glx libX11 libXxf86vm libnsl
for archive in *_Package.zip; do unzip -tq "$archive"; done
if [ -b /dev/vda4 ] && [ "$(pvs --noheadings -o vg_name /dev/vda4 | xargs)" = vg_main ]; then
    set +e
    growpart /dev/vda 4
    grow_result=$?
    set -e
    if [ "$grow_result" -gt 1 ]; then exit "$grow_result"; fi
    pvresize /dev/vda4
    if [ "$(vgs --noheadings -o vg_free_count vg_main | xargs)" -gt 0 ]; then
        lvextend --resizefs --extents +100%FREE /dev/vg_main/lv_root
    fi
fi
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
sed -i '/SDM_localhost/d; /^127\.0\.1\.1[[:space:]]/d' /etc/hosts
printf '\n%s sdm-kubevirt SDM_localhost\n' "$guest_ip" >> /etc/hosts
# Preserve the SDM alias when cloud-init refreshes /etc/hosts on later boots.
if [ -f /etc/cloud/templates/hosts.redhat.tmpl ]; then
    sed -i '/SDM_localhost/d; /^127\.0\.1\.1[[:space:]]/d' /etc/cloud/templates/hosts.redhat.tmpl
    printf '\n%s sdm-kubevirt SDM_localhost\n' "$guest_ip" >> /etc/cloud/templates/hosts.redhat.tmpl
fi
python3 - <<'PY'
from pathlib import Path
names = {'sdm', 'sdm-kubevirt', '{{fqdn}}', '{{hostname}}'}
for filename in ['/etc/hosts', '/etc/cloud/templates/hosts.redhat.tmpl']:
    p = Path(filename)
    if not p.exists():
        continue
    result = []
    for line in p.read_text().splitlines():
        parts = line.split()
        if parts and (parts[0].startswith('127.') or parts[0] == '::1') and any(name in parts[1:] for name in names):
            aliases = [name for name in parts[1:] if name not in names]
            if aliases:
                result.append(parts[0] + ' ' + ' '.join(aliases))
        else:
            result.append(line)
    p.write_text('\n'.join(result) + '\n')
PY
tar -xzf "$media/NNC90_5OracleLinux90_64bit.tar.gz" -C /opt
chown -R nncentral:nncentral /opt/AcmePacket
cat > /etc/sudoers.d/sdm-trap-relay <<'EOF'
nncentral ALL=(root) /opt/AcmePacket/NNC90_5/jre/bin/java * -Dlog4j.configuration*=* -cp * com.acmepacket.ems.server.services.snmp.TrapRelay.TrapRelay *
EOF
chmod 440 /etc/sudoers.d/sdm-trap-relay
visudo -cf /etc/sudoers.d/sdm-trap-relay
cat > /etc/security/limits.d/90-sdm.conf <<'EOF'
nncentral soft nofile 65536
nncentral hard nofile 65536
EOF
ulimit -n 65536
if systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port=8443/tcp --add-port=162/udp
    firewall-cmd --reload
fi
cd "$sdm_home/bin"
# The 9.0.5 headless CSR caller still waits for an interactive OpenSSL prompt.
# Scope the previously verified prompt adapter to this setup invocation only.
install -d -o root -g root -m 755 /opt/sdm-headless-tools
install -o root -g root -m 755 /home/hkl/openssl-wrapper.sh /opt/sdm-headless-tools/openssl
cat >> "$sdm_home/setEnv.sh" <<'EOF'

# Used only by automated headless setup; normal SDM runtime keeps vendor OpenSSL.
if [ -n "${SDM_HEADLESS_OPENSSL_PATH:-}" ]; then
    export PATH="$SDM_HEADLESS_OPENSSL_PATH:$PATH"
fi
EOF
(umask 022; SDM_HEADLESS_OPENSSL_PATH=/opt/sdm-headless-tools SDM_CERT_HOSTNAME=sdm-kubevirt ./setup.sh --headless /root/sdm-setup.properties)
test -f /opt/AcmePacket/setup_config.ini
chown -R nncentral:nncentral /opt/AcmePacket
cat > /etc/systemd/system/sdm.service <<'EOF'
[Unit]
Description=Oracle Communications Session Delivery Manager lab
After=network-online.target cloud-final.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=nncentral
Group=nncentral
WorkingDirectory=/opt/AcmePacket/NNC90_5/bin
Environment=LANG=en_US.UTF-8
LimitNOFILE=65536
ExecStart=/bin/bash /opt/AcmePacket/NNC90_5/bin/startnnc.sh --nomonitor
ExecStop=/bin/bash /opt/AcmePacket/NNC90_5/bin/shutdownnnc.sh
TimeoutStartSec=180
TimeoutStopSec=180

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now sdm
touch /root/sdm-install-complete
echo 'SDM installation completed. Credentials are in /root/sdm-lab-credentials.txt.'
