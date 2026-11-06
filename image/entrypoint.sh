#!/bin/bash
set -Eeuo pipefail
sdm_home=/opt/AcmePacket/NNC90_5
state=/opt/AcmePacket
if [ "$(id -u)" -ne 0 ]; then
    echo 'Experimental lab image requires root inside the container for SDM setup and trap relay.' >&2
    exit 1
fi
if [ ! -f "$sdm_home/bin/startnnc.sh" ]; then
    cp -a /usr/share/sdm-seed/AcmePacket/. "$state/"
    chown -R nncentral:nncentral "$state"
fi
container_ip=$(hostname -I | awk '{print $1}')
if [ -z "$container_ip" ]; then echo 'No container IPv4 address found' >&2; exit 1; fi
# Podman may inherit the host's SDM_localhost entry. Never retain that address.
sed '/SDM_localhost/d' /etc/hosts > /tmp/sdm-hosts
cat /tmp/sdm-hosts > /etc/hosts
printf '\n%s %s SDM_localhost\n' "$container_ip" "$(hostname)" >> /etc/hosts
if [ ! -r /run/secrets/sdm_setup ]; then
    echo 'Mount a populated headless setup properties file at /run/secrets/sdm_setup.' >&2
    exit 1
fi
# Recreated containers also need the account password restored outside the volume.
nn_password=$(sed -n 's/^SFTP_PASSWORD=//p' /run/secrets/sdm_setup | head -1)
if [ -z "$nn_password" ]; then echo 'SFTP_PASSWORD is required' >&2; exit 1; fi
printf 'nncentral:%s\n' "$nn_password" | chpasswd
unset nn_password
# Recreate the container-local policy, rather than rely on setup modifying /etc.
# This is a lab exception: nncentral can run the bundled Java as container root.
printf '%s\n' 'nncentral ALL=(root) /opt/AcmePacket/NNC90_5/jre/bin/java' > /etc/sudoers.d/sdm-lab-trap-relay
chmod 440 /etc/sudoers.d/sdm-lab-trap-relay
visudo -cf /etc/sudoers.d/sdm-lab-trap-relay >/dev/null
if ! grep -q '/opt/sdm-tools' "$sdm_home/setEnv.sh"; then
    printf '\nexport PATH=/opt/sdm-tools:$PATH\n' >> "$sdm_home/setEnv.sh"
fi
export SDM_CERT_HOSTNAME
SDM_CERT_HOSTNAME=$(sed -n 's/^SERVER_NAME=//p' /run/secrets/sdm_setup | head -1)
if [ ! -f "$state/.lab-setup-complete" ]; then
    cd "$sdm_home/bin"
    ./setup.sh --headless /run/secrets/sdm_setup
    # SDM scripts can return success even on validation errors. Require generated config.
    if [ ! -f "$state/setup_config.ini" ]; then
        echo 'Setup did not produce setup_config.ini' >&2; exit 1
    fi
    printf '%s\n' "$container_ip" > "$state/.lab-setup-ip"
    touch "$state/.lab-setup-complete"
elif [ "$(cat "$state/.lab-setup-ip")" != "$container_ip" ]; then
    echo 'Container IP changed. Reconfigure SDM before reusing this lab volume.' >&2
    exit 1
fi
cd "$sdm_home/bin"
stop_sdm() {
    trap - TERM INT
    echo 'Stopping SDM gracefully'
    runuser -u nncentral -- ./shutdownnnc.sh || true
    exit 0
}
trap stop_sdm TERM INT
runuser -u nncentral -- ./startnnc.sh --nomonitor
echo 'SDM startup requested; waiting for back-end process'
sleep 10 & wait $!
if ! pgrep -f '[c]om.acmepacket.ems.server.main.BEServer' >/dev/null; then
    tail -n 80 "$sdm_home/logs/console.out" 2>/dev/null || true
    echo 'SDM back-end process did not remain running' >&2
    exit 1
fi
while pgrep -f '[c]om.acmepacket.ems.server.main.BEServer' >/dev/null; do
    sleep 10 & wait $!
done
echo 'SDM back-end process exited' >&2
exit 1
