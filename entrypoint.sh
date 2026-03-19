#!/bin/sh
# ==============================================================================
# NEOXAGENT - ENTRYPOINT UNIFICADO (TProxy primero, Firewall después)
# ORDEN CORRECTO:
# 1. Lanzar tproxy en background (se conecta al proxy SOCKS5 libremente)
# 2. Esperar a que esté listo (puerto 1080 activo)
# 3. Aplicar iptables kill-switch (ahora tproxy ya está conectado)
# 4. Esperar que tproxy termine (actúa como proceso principal)
# ==============================================================================
set -e

CONFIG_FILE="/config.yaml"
IPTABLES_SCRIPT="/iptables-setup.sh"

# --- Paso 1: Lanzar tproxy en background (SIN firewall aún) ---
echo "[entrypoint] Iniciando hev-socks5-tproxy..."
hev-socks5-tproxy "$CONFIG_FILE" &
TPROXY_PID=$!

# --- Paso 2: Esperar a que tproxy esté escuchando en 1080 ---
echo "[entrypoint] Esperando que tproxy esté listo..."
for i in $(seq 1 30); do
    if nc -z 127.0.0.1 1080 2>/dev/null; then
        echo "[entrypoint] TProxy listo (intento $i)."
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "[entrypoint] ERROR: TProxy no respondió en 30s. Abortando."
        kill $TPROXY_PID 2>/dev/null
        exit 1
    fi
    sleep 1
done

# --- Paso 3: Aplicar firewall DESPUÉS de que tproxy está conectado ---
if [ -f "$IPTABLES_SCRIPT" ]; then
    echo "[entrypoint] Inyectando reglas de firewall..."
    sh "$IPTABLES_SCRIPT"
    echo "[entrypoint] Firewall blindado activo."
else
    echo "[entrypoint] WARN: No se encontró iptables-setup.sh. Sin firewall."
fi

# --- Paso 4: Mantener el contenedor vivo mientras tproxy corra ---
echo "[entrypoint] Todo activo. Monitoreando tproxy (PID $TPROXY_PID)..."
wait $TPROXY_PID
echo "[entrypoint] TProxy terminó. Saliendo."
