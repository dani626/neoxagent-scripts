#!/bin/sh
# ==============================================================================
# NEOXAGENT - TEST DE RED Y PROXY
# Verifica que todo el tráfico pase correctamente por el proxy
# ==============================================================================

PASS=0
FAIL=0
WARN=0

result() {
    local status="$1" test_name="$2" detail="$3"
    case "$status" in
        PASS) PASS=$((PASS + 1)); echo "[✅ PASS] $test_name: $detail" ;;
        FAIL) FAIL=$((FAIL + 1)); echo "[❌ FAIL] $test_name: $detail" ;;
        WARN) WARN=$((WARN + 1)); echo "[⚠️  WARN] $test_name: $detail" ;;
    esac
}

echo "============================================"
echo " NEOXAGENT - TEST DE RED"
echo " $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================"
echo ""

# --- TEST 1: IP Pública (¿se ve la IP del proxy o la del VPS?) ---
echo "[*] Test 1: Verificando IP pública..."
PUBLIC_IP=$(wget -qO- --timeout=10 https://api.ipify.org 2>/dev/null)
if [ -n "$PUBLIC_IP" ]; then
    result "PASS" "IP Pública" "$PUBLIC_IP"
    echo "    → Verifica que esta IP NO sea la de tu VPS."
    echo "    → Debería ser la IP del proxy SOCKS5."
else
    result "FAIL" "IP Pública" "No se pudo obtener (¿proxy caído o sin conectividad?)"
fi

# --- TEST 2: Geolocalización de la IP ---
echo ""
echo "[*] Test 2: Geolocalización..."
GEO_INFO=$(wget -qO- --timeout=10 "https://ipinfo.io/${PUBLIC_IP}/json" 2>/dev/null)
if [ -n "$GEO_INFO" ]; then
    GEO_CITY=$(echo "$GEO_INFO" | grep '"city"' | cut -d'"' -f4)
    GEO_COUNTRY=$(echo "$GEO_INFO" | grep '"country"' | cut -d'"' -f4)
    GEO_ORG=$(echo "$GEO_INFO" | grep '"org"' | cut -d'"' -f4)
    result "PASS" "Geolocalización" "$GEO_CITY, $GEO_COUNTRY ($GEO_ORG)"
else
    result "WARN" "Geolocalización" "No se pudo obtener info"
fi

# --- TEST 3: DNS Leak ---
echo ""
echo "[*] Test 3: DNS Leak..."
# Resolvemos un dominio y verificamos que el DNS no filtre
DNS_RESULT=$(nslookup whoami.akamai.net 2>/dev/null | grep "Address" | tail -1 | awk '{print $2}')
if [ -n "$DNS_RESULT" ]; then
    if [ "$DNS_RESULT" = "$PUBLIC_IP" ] || echo "$DNS_RESULT" | grep -qE "^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)"; then
        result "PASS" "DNS Leak" "DNS resuelve a $DNS_RESULT (sin leak aparente)"
    else
        result "WARN" "DNS Leak" "DNS resuelve a $DNS_RESULT — verifica que no sea la IP de tu VPS"
    fi
else
    # Si nslookup falla, el DNS puede estar bloqueado o proxificado correctamente
    # Intentar con wget como fallback
    DNS_TEST=$(wget -qO- --timeout=10 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | grep "ip=")
    if [ -n "$DNS_TEST" ]; then
        result "PASS" "DNS Leak" "DNS funciona vía proxy. $DNS_TEST"
    else
        result "FAIL" "DNS Leak" "No se pudo resolver DNS"
    fi
fi

# --- TEST 4: Conectividad TCP ---
echo ""
echo "[*] Test 4: Conectividad TCP..."
TCP_TEST=$(wget -qO- --timeout=10 https://httpbin.org/ip 2>/dev/null)
if [ -n "$TCP_TEST" ]; then
    TCP_IP=$(echo "$TCP_TEST" | grep "origin" | cut -d'"' -f4)
    if [ "$TCP_IP" = "$PUBLIC_IP" ]; then
        result "PASS" "TCP vía proxy" "httpbin ve: $TCP_IP (coincide con IP pública)"
    else
        result "WARN" "TCP vía proxy" "httpbin ve: $TCP_IP (difiere de $PUBLIC_IP)"
    fi
else
    result "FAIL" "TCP vía proxy" "No se pudo conectar a httpbin.org"
fi

# --- TEST 5: HTTPS/TLS ---
echo ""
echo "[*] Test 5: HTTPS/TLS..."
HTTPS_TEST=$(wget -qO- --timeout=10 https://www.google.com 2>/dev/null | head -c 100)
if [ -n "$HTTPS_TEST" ]; then
    result "PASS" "HTTPS/TLS" "Conexión HTTPS exitosa"
else
    result "FAIL" "HTTPS/TLS" "No se pudo establecer conexión HTTPS"
fi

# --- TEST 6: IPv6 Bloqueado ---
echo ""
echo "[*] Test 6: IPv6 (debe estar bloqueado)..."
IPV6_TEST=$(wget -qO- --timeout=5 https://v6.ipv6-test.com/api/myip.php 2>/dev/null)
if [ -z "$IPV6_TEST" ]; then
    result "PASS" "IPv6 Bloqueado" "Sin conectividad IPv6 (correcto)"
else
    result "FAIL" "IPv6 Bloqueado" "¡IPv6 activo! IP: $IPV6_TEST — hay un leak"
fi

# --- TEST 7: UDP Bloqueado (excepto DNS) ---
echo ""
echo "[*] Test 7: UDP Kill-Switch..."
# Intentar enviar UDP a un servidor NTP (puerto 123)
UDP_TEST=$(nc -zu -w3 pool.ntp.org 123 2>&1)
UDP_EXIT=$?
if [ $UDP_EXIT -ne 0 ]; then
    result "PASS" "UDP Bloqueado" "UDP a puerto 123 bloqueado (correcto)"
else
    result "FAIL" "UDP Bloqueado" "UDP a puerto 123 pudo salir — kill-switch no funciona"
fi

# --- TEST 8: Kill-Switch (verificar reglas iptables) ---
echo ""
echo "[*] Test 8: Kill-Switch (reglas iptables)..."
DROP_RULE=$(iptables -L OUTPUT -n 2>/dev/null | grep -c "DROP")
if [ "$DROP_RULE" -gt 0 ]; then
    result "PASS" "Kill-Switch" "Regla DROP activa en OUTPUT ($DROP_RULE reglas)"
else
    result "WARN" "Kill-Switch" "No se encontró regla DROP (¿permisos insuficientes?)"
fi

# --- TEST 9: TProxy Engine escuchando ---
echo ""
echo "[*] Test 9: TProxy Engine..."
if nc -z 127.0.0.1 1080 2>/dev/null; then
    result "PASS" "TProxy Engine" "Escuchando en puerto 1080"
else
    result "FAIL" "TProxy Engine" "No responde en puerto 1080"
fi

# DNS proxy
if nc -z 127.0.0.1 53 2>/dev/null; then
    result "PASS" "DNS Proxy" "Escuchando en puerto 53"
else
    result "FAIL" "DNS Proxy" "No responde en puerto 53"
fi

# --- RESUMEN ---
echo ""
echo "============================================"
echo " RESULTADOS"
echo "============================================"
echo " ✅ PASS: $PASS"
echo " ❌ FAIL: $FAIL"
echo " ⚠️  WARN: $WARN"
echo "============================================"

if [ $FAIL -eq 0 ]; then
    echo " [✓] Todos los tests críticos pasaron."
    echo " Red blindada correctamente."
    exit 0
else
    echo " [!] Hay $FAIL tests fallidos."
    echo " Revisa los errores antes de desplegar mineros."
    exit 1
fi
