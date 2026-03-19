#!/bin/sh
# ==============================================================================
# NEOXAGENT - ENTRYPOINT UNIFICADO (Firewall + TProxy)
# 1. Inyecta reglas iptables de forma SÍNCRONA
# 2. Lanza hev-socks5-tproxy
# ==============================================================================
set -e

CONFIG_FILE="/config.yaml"
IPTABLES_SCRIPT="/iptables-setup.sh"

# --- Paso 1: Inyectar reglas iptables (SÍNCRONO, no en background) ---
if [ -f "$IPTABLES_SCRIPT" ]; then
    echo "[entrypoint] Inyectando reglas de firewall..."
    sh "$IPTABLES_SCRIPT"
    echo "[entrypoint] Firewall activo."
else
    echo "[entrypoint] WARN: No se encontró $IPTABLES_SCRIPT. Ejecutando sin firewall."
fi

# --- Paso 2: Lanzar TProxy ---
echo "[entrypoint] Iniciando hev-socks5-tproxy..."
exec hev-socks5-tproxy "$CONFIG_FILE"
