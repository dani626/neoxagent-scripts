#!/bin/sh
# ==============================================================================
# NEOXAGENT - ENTRYPOINT UNIFICADO (Firewall + TProxy)
# 1. Inyecta reglas iptables (firewall blindado)
# 2. Lanza hev-socks5-tproxy
# ==============================================================================
set -e

CONFIG_FILE="/config.yaml"
IPTABLES_SCRIPT="/iptables-setup.sh"

# --- Paso 1: Inyectar reglas iptables si el script existe ---
if [ -f "$IPTABLES_SCRIPT" ]; then
    echo "[entrypoint] Inyectando reglas de firewall..."
    sh "$IPTABLES_SCRIPT" &
    IPTABLES_PID=$!

    # Esperar a que las reglas se apliquen (máximo 5s)
    for i in $(seq 1 10); do
        if iptables -t mangle -L OUTPUT -n 2>/dev/null | grep -q "MARK"; then
            echo "[entrypoint] Firewall activo."
            break
        fi
        sleep 0.5
    done
else
    echo "[entrypoint] WARN: No se encontró $IPTABLES_SCRIPT. Ejecutando sin firewall."
fi

# --- Paso 2: Lanzar TProxy ---
echo "[entrypoint] Iniciando hev-socks5-tproxy..."
exec hev-socks5-tproxy -c "$CONFIG_FILE"
