#!/bin/bash
# ==============================================================================
# NEOXAGENT - MOTOR DE DESPLIEGUE TPROXY (INTELIGENTE)
# Uso: ./neoxagent-deploy.sh [archivo.conf]
#      ./neoxagent-deploy.sh --install [archivo.conf]
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPROXY_IMAGE="localhost/hev-socks5-tproxy:latest"
INSTALL_MODE=false

# Detectar flag --install
if [[ "${1:-}" == "--install" ]]; then
    INSTALL_MODE=true
    shift
fi

# El primer argumento (después de --install) es el archivo de config
CONFIG_FILE="${1:-$SCRIPT_DIR/neoxagent.conf}"

# --- FUNCIONES AUXILIARES ---
deploy_miner() {
    local name="$1" image="$2"; shift 2
    echo "[+] Iniciando $name..."
    podman run -d --pod "$POD_NAME" --name "${POD_NAME}-${name}" \
      --restart unless-stopped --cpus="0.2" --memory="150m" \
      --log-opt max-size=10m --log-opt max-file=1 \
      "$image" "$@"
}

generate_systemd() {
    local service_name="neoxagent-${POD_NAME}"
    local service_file="/etc/systemd/system/${service_name}.service"
    local abs_config
    abs_config="$(readlink -f "$CONFIG_FILE")"
    local abs_script
    abs_script="$(readlink -f "$0")"

    echo "[*] Generando servicio systemd: ${service_name}..."
    cat <<SVCEOF | sudo tee "$service_file" > /dev/null
[Unit]
Description=NeoxAgent TProxy Pod - ${POD_NAME}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash ${abs_script} ${abs_config}
ExecStop=/usr/bin/podman pod rm -f ${POD_NAME}
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
SVCEOF

    sudo systemctl daemon-reload
    sudo systemctl enable "${service_name}.service"
    echo "[✓] Servicio ${service_name} instalado y habilitado."
    echo "    Comandos útiles:"
    echo "    sudo systemctl status ${service_name}"
    echo "    sudo systemctl restart ${service_name}"
    echo "    sudo journalctl -u ${service_name}"
}

# --- 1. VALIDACIONES PREVIAS ---
if ! command -v podman &>/dev/null; then
    echo "[!] Error: Podman no está instalado."
    exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "[!] Error: No se encuentra el archivo $CONFIG_FILE. Ejecución abortada."
    exit 1
fi

# Validar que el config no contenga comandos peligrosos antes de hacer source
if grep -qP '(?<!=)[`$]\(' "$CONFIG_FILE" 2>/dev/null; then
    echo "[!] Error: El archivo de configuración contiene caracteres sospechosos. Abortando."
    exit 1
fi

# Verificar que la imagen tproxy unificada existe
if ! podman image exists "$TPROXY_IMAGE" 2>/dev/null; then
    echo "[!] Imagen $TPROXY_IMAGE no encontrada. Construyendo..."
    if [ -f "$SCRIPT_DIR/Dockerfile.tproxy" ]; then
        podman build -t "$TPROXY_IMAGE" -f "$SCRIPT_DIR/Dockerfile.tproxy" "$SCRIPT_DIR"
    else
        echo "[!] Error: No se encuentra Dockerfile.tproxy. Ejecuta primero:"
        echo "    podman build -t $TPROXY_IMAGE -f Dockerfile.tproxy ."
        exit 1
    fi
fi

source "$CONFIG_FILE"

# POD_NAME ahora viene del config (con fallback)
POD_NAME="${POD_NAME:-tproxy-pod}"
SETUP_DIR="$HOME/traff-setup/${POD_NAME}"

echo "[*] Configuración cargada: Pod=$POD_NAME, Proxy=$PROXY_IP:$PROXY_PORT"

# --- 2. LIMPIEZA Y PREPARACIÓN ---
echo "[*] Limpiando despliegues anteriores..."
podman pod rm -f "$POD_NAME" 2>/dev/null || true
mkdir -p "$SETUP_DIR"

# --- 3. CONFIGURACIÓN DEL TÚNEL TPROXY ---
echo "[*] Generando config.yaml para el proxy..."
cat <<EOF > "$SETUP_DIR/config.yaml"
socks5:
  address: ${PROXY_IP}
  port: ${PROXY_PORT}
  username: ${PROXY_USER}
  password: ${PROXY_PASS}
tcp:
  address: 0.0.0.0
  port: 1080
dns:
  address: 0.0.0.0
  port: 53
  upstream: 8.8.4.4
  rewrite: true
EOF
chmod 600 "$SETUP_DIR/config.yaml"

# --- 4. SCRIPT DE IPTABLES BLINDADO ---
echo "[*] Generando script de iptables..."
cat <<'IPTEOF_HEADER' > "$SETUP_DIR/iptables-setup.sh"
#!/bin/sh
# ==============================================================================
# NEOXAGENT - IPTABLES BLINDADO
# - Redirige TODO TCP vía TPROXY (proxy SOCKS5 transparente)
# - Redirige DNS (UDP 53) al tproxy DNS listener
# - Kill-switch: si tproxy se cae, NADA sale
# - IPv6 bloqueado totalmente
# ==============================================================================
set -e

IPTEOF_HEADER

# Inyectar la IP del proxy (necesita expansión de variable)
cat <<IPTEOF_VARS >> "$SETUP_DIR/iptables-setup.sh"
PROXY_IP="${PROXY_IP}"
IPTEOF_VARS

cat <<'IPTEOF_BODY' >> "$SETUP_DIR/iptables-setup.sh"

# --- Limpiar reglas existentes ---
iptables -t mangle -F 2>/dev/null || true
iptables -F OUTPUT 2>/dev/null || true
ip6tables -F OUTPUT 2>/dev/null || true
ip6tables -F INPUT 2>/dev/null || true
ip6tables -F FORWARD 2>/dev/null || true

# ==============================================================================
# IPv4 - ROUTING POLICY
# ==============================================================================
ip rule add fwmark 1 lookup 100 2>/dev/null || true
ip route replace local 0.0.0.0/0 dev lo table 100

# ==============================================================================
# IPv4 - MANGLE (Marcar tráfico para TPROXY)
# ==============================================================================
# Excluir tráfico directo al proxy (evitar bucle)
iptables -t mangle -A OUTPUT -d "$PROXY_IP" -j RETURN

# Excluir redes locales/privadas
iptables -t mangle -A OUTPUT -d 127.0.0.0/8 -j RETURN
iptables -t mangle -A OUTPUT -d 10.0.0.0/8 -j RETURN
iptables -t mangle -A OUTPUT -d 172.16.0.0/12 -j RETURN
iptables -t mangle -A OUTPUT -d 192.168.0.0/16 -j RETURN

# Marcar TODO TCP para TPROXY
iptables -t mangle -A OUTPUT -p tcp -j MARK --set-mark 1

# Marcar DNS (UDP 53) para TPROXY
iptables -t mangle -A OUTPUT -p udp --dport 53 -j MARK --set-mark 1

# ==============================================================================
# IPv4 - PREROUTING (Aplicar TPROXY a tráfico marcado)
# ==============================================================================
# TCP → puerto 1080 (proxy SOCKS5 transparente)
iptables -t mangle -A PREROUTING -p tcp -m mark --mark 1 -j TPROXY --on-port 1080 --tproxy-mark 1

# DNS (UDP 53) → puerto 53 del tproxy (DNS proxy)
iptables -t mangle -A PREROUTING -p udp --dport 53 -m mark --mark 1 -j TPROXY --on-port 53 --tproxy-mark 1

# ==============================================================================
# IPv4 - KILL-SWITCH
# ==============================================================================
# Permitir tráfico al proxy real
iptables -A OUTPUT -d "$PROXY_IP" -j ACCEPT

# Permitir loopback y redes privadas
iptables -A OUTPUT -d 127.0.0.0/8 -j ACCEPT
iptables -A OUTPUT -d 10.0.0.0/8 -j ACCEPT
iptables -A OUTPUT -d 172.16.0.0/12 -j ACCEPT
iptables -A OUTPUT -d 192.168.0.0/16 -j ACCEPT

# Permitir tráfico marcado (ya va por TPROXY)
iptables -A OUTPUT -m mark --mark 1 -j ACCEPT

# BLOQUEAR todo lo demás (kill-switch)
iptables -A OUTPUT -j DROP

# ==============================================================================
# IPv6 - BLOQUEO TOTAL
# ==============================================================================
ip6tables -P INPUT DROP
ip6tables -P OUTPUT DROP
ip6tables -P FORWARD DROP
ip6tables -A INPUT -i lo -j ACCEPT
ip6tables -A OUTPUT -o lo -j ACCEPT

echo "[iptables] Firewall blindado activo."
IPTEOF_BODY

chmod 700 "$SETUP_DIR/iptables-setup.sh"

# --- 5. CREACIÓN DEL POD BLINDADO ---
echo "[*] Creando Pod..."
podman pod create --name "$POD_NAME" \
  --sysctl net.ipv4.conf.all.rp_filter=0 \
  --sysctl net.ipv4.conf.lo.rp_filter=0 \
  --sysctl net.ipv6.conf.all.disable_ipv6=1

# --- 6. MOTOR UNIFICADO (TProxy + Firewall) ---
echo "[*] Levantando TProxy Engine + Firewall..."
podman run -d --pod "$POD_NAME" --name "${POD_NAME}-tproxy" \
  --restart unless-stopped --cpus="0.3" --memory="128m" \
  --log-opt max-size=10m --log-opt max-file=1 \
  --cap-add=NET_ADMIN \
  -v "$SETUP_DIR/config.yaml:/config.yaml:Z" \
  -v "$SETUP_DIR/iptables-setup.sh:/iptables-setup.sh:Z" \
  "$TPROXY_IMAGE"

# Esperar a que el firewall esté activo
echo "[*] Esperando firewall..."
for i in $(seq 1 20); do
    if podman logs "${POD_NAME}-tproxy" 2>&1 | grep -q "Firewall blindado activo" 2>/dev/null; then
        echo "[✓] TProxy + Firewall activos."
        break
    fi
    if [ "$i" -eq 20 ]; then
        echo "[!] WARN: No se pudo confirmar el firewall. Verifica con:"
        echo "    podman logs ${POD_NAME}-tproxy"
    fi
    sleep 2
done

# ==============================================================================
# MODO TEST vs DESPLIEGUE DE MINEROS
# ==============================================================================

if [ "${TEST_MODE:-false}" = "true" ]; then
    # --- MODO TEST: Solo verificar red y proxy ---
    echo ""
    echo "[🔍] MODO TEST ACTIVADO — No se instalarán mineros."
    echo "[*] Ejecutando tests de red dentro del pod..."

    podman run --rm --pod "$POD_NAME" --name "${POD_NAME}-nettest" \
      --cap-add=NET_ADMIN \
      -v "$SCRIPT_DIR/network-test.sh:/network-test.sh:Z" \
      alpine sh -c "apk add --no-cache wget bind-tools netcat-openbsd iptables > /dev/null 2>&1 && sh /network-test.sh"

    TEST_EXIT=$?
    echo ""
    if [ $TEST_EXIT -eq 0 ]; then
        echo "[✓] Tests completados. La red está blindada."
        echo "    Para desplegar mineros, cambia TEST_MODE=\"false\" en el config y re-ejecuta."
    else
        echo "[!] Hay tests fallidos. Revisa antes de desplegar mineros."
    fi

else
    # --- MODO PRODUCCIÓN: Desplegar mineros ---

    # 1. TRAFFMONETIZER
    if [ -n "${TRAFF_TOKEN:-}" ]; then
        deploy_miner "traff" "docker.io/traffmonetizer/cli_v2" start accept --token "$TRAFF_TOKEN"
    fi

    # 2. PACKETSTREAM
    if [ -n "${PACKETSTREAM_CID:-}" ]; then
        deploy_miner "packetstream" "docker.io/packetstream/psclient:latest" --cid "$PACKETSTREAM_CID"
    fi

    # 3. EARNAPP
    if [ -n "${EARNAPP_UUID_DIR:-}" ]; then
        echo "[+] Directorio detectado. Iniciando EarnApp..."
        mkdir -p "$EARNAPP_UUID_DIR"
        podman run -d --pod "$POD_NAME" --name "${POD_NAME}-earnapp" \
          --restart unless-stopped --cpus="0.3" --memory="250m" \
          --log-opt max-size=10m --log-opt max-file=1 \
          -v "$EARNAPP_UUID_DIR:/etc/earnapp:Z" \
          docker.io/fazalfarhan01/earnapp:lite
    fi

    # 4. PAWNS.APP (Requiere que ambos campos estén llenos)
    if [[ -n "${PAWNS_EMAIL:-}" && -n "${PAWNS_PASS:-}" ]]; then
        echo "[+] Credenciales detectadas. Iniciando Pawns.app..."
        podman run -d --pod "$POD_NAME" --name "${POD_NAME}-pawns" \
          --restart unless-stopped --cpus="0.2" --memory="150m" \
          --log-opt max-size=10m --log-opt max-file=1 \
          -e PAWNS_EMAIL="$PAWNS_EMAIL" \
          -e PAWNS_PASSWORD="$PAWNS_PASS" \
          -e PAWNS_DEVICE_NAME="${PAWNS_DEVICE_NAME:-VPS-Node-1}" \
          -e PAWNS_DEVICE_ID="${PAWNS_DEVICE_NAME:-VPS-Node-1}" \
          docker.io/iproyal/pawns-cli:latest -accept-tos
    fi

    # 5. REPOCKET (Requiere que ambos campos estén llenos)
    if [[ -n "${REPOCKET_EMAIL:-}" && -n "${REPOCKET_API:-}" ]]; then
        echo "[+] API detectada. Iniciando Repocket..."
        podman run -d --pod "$POD_NAME" --name "${POD_NAME}-repocket" \
          --restart unless-stopped --cpus="0.2" --memory="150m" \
          --log-opt max-size=10m --log-opt max-file=1 \
          -e RP_EMAIL="$REPOCKET_EMAIL" -e RP_API_KEY="$REPOCKET_API" \
          docker.io/repocket/repocket:latest
    fi

    # 6. EARN.FM
    if [ -n "${EARNFM_TOKEN:-}" ]; then
        echo "[+] Token detectado. Iniciando Earn.fm..."
        podman run -d --pod "$POD_NAME" --name "${POD_NAME}-earnfm" \
          --restart unless-stopped --cpus="0.2" --memory="150m" \
          --log-opt max-size=10m --log-opt max-file=1 \
          -e EARNFM_TOKEN="$EARNFM_TOKEN" \
          docker.io/earnfm/earnfm-client:latest
    fi

    # 7. PROXYRACK
    if [ -n "${PROXYRACK_UUID:-}" ]; then
        echo "[+] UUID detectado. Iniciando Proxyrack..."
        podman run -d --pod "$POD_NAME" --name "${POD_NAME}-proxyrack" \
          --restart unless-stopped --cpus="0.2" --memory="150m" \
          --log-opt max-size=10m --log-opt max-file=1 \
          -e UUID="$PROXYRACK_UUID" \
          docker.io/proxyrack/pop:latest
    fi

fi

# --- INSTALACIÓN SYSTEMD (OPCIONAL) ---
if [ "$INSTALL_MODE" = true ]; then
    generate_systemd
fi

# --- RESUMEN FINAL ---
echo ""
echo "[✓] Despliegue completado: $POD_NAME"
echo "[*] Contenedores activos:"
podman ps --pod --filter "pod=$POD_NAME" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"