#!/usr/bin/env bash
# Panel profesional BHTTP. El servidor Python y el protocolo se conservan.
set -Eeuo pipefail

APP="BHTTP Control"
DESTDIR="/usr/local/lib/bhttp"
SERVER_PY="$DESTDIR/bhttp-server.py"
UNIT="/etc/systemd/system/bhttp.service"
CONF_DIR="/etc/bhttp"
CONF="$CONF_DIR/manager.conf"
SERVICE="bhttp"

# Valores iniciales
BHTTP_PORT=8080
BACKEND_PORT=22
RCVBUF_KB=0
SNDBUF_KB=0
WRITE_HIGH_KB=256
STREAM_LIMIT_KB=256

C_RESET='\033[0m'; C_CYAN='\033[36m'; C_GREEN='\033[32m'
C_YELLOW='\033[33m'; C_RED='\033[31m'; C_DIM='\033[2m'; C_BOLD='\033[1m'

line() { printf '%b\n' "${C_DIM}────────────────────────────────────────────────────────${C_RESET}"; }
ok() { printf '%b\n' "${C_GREEN}✓${C_RESET} $*"; }
warn() { printf '%b\n' "${C_YELLOW}!${C_RESET} $*"; }
err() { printf '%b\n' "${C_RED}✗ $*${C_RESET}" >&2; }
need_root() { [[ $(id -u) -eq 0 ]] || { err "Ejecuta con sudo: sudo bash $0"; exit 1; }; }
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
valid_buffer() { [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 <= 16384 )); }

banner() {
  clear 2>/dev/null || true
  printf '%b\n' "${C_CYAN}${C_BOLD}  BHTTP CONTROL PANEL${C_RESET}"
  printf '%b\n' "  ${C_DIM}Administración del servidor · protocolo BHTTP original${C_RESET}"
  line
}

load_config() {
  mkdir -p "$CONF_DIR"
  if [[ -f "$CONF" ]]; then
    # Configuración generada por este panel; contiene únicamente valores numéricos.
    source "$CONF"
  fi
}

save_config() {
  install -d -m 755 "$CONF_DIR"
  cat > "$CONF" <<EOF
BHTTP_PORT=$BHTTP_PORT
BACKEND_PORT=$BACKEND_PORT
RCVBUF_KB=$RCVBUF_KB
SNDBUF_KB=$SNDBUF_KB
WRITE_HIGH_KB=$WRITE_HIGH_KB
STREAM_LIMIT_KB=$STREAM_LIMIT_KB
EOF
  chmod 600 "$CONF"
}

write_service() {
  local pybin
  pybin="$(command -v python3)"
  cat > "$UNIT" <<EOF
[Unit]
Description=BHTTP Server
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=$pybin $SERVER_PY --host 0.0.0.0 --port $BHTTP_PORT --backend-host 127.0.0.1 --backend-port $BACKEND_PORT --rcvbuf-kb $RCVBUF_KB --sndbuf-kb $SNDBUF_KB --write-high-kb $WRITE_HIGH_KB --stream-limit-kb $STREAM_LIMIT_KB
Restart=always
RestartSec=2
TimeoutStopSec=20
KillSignal=SIGINT
LimitNOFILE=65535
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$SERVICE" >/dev/null
}

apply_config() {
  save_config
  if [[ ! -f "$SERVER_PY" ]]; then
    warn "Configuración guardada. Instala el servidor para activarla."
    return 0
  fi
  write_service
  systemctl restart "$SERVICE"
  sleep 1
  systemctl is-active --quiet "$SERVICE" && ok "Configuración aplicada; BHTTP está activo." || { err "El servicio no arrancó. Revisa los logs."; return 1; }
}

install_server() {
  local pybin
  command -v python3 >/dev/null 2>&1 || {
    if command -v apt-get >/dev/null 2>&1; then apt-get update && apt-get install -y python3;
    elif command -v dnf >/dev/null 2>&1; then dnf install -y python3;
    else err "Instala Python 3 y vuelve a intentarlo."; return 1; fi
  }
  command -v systemctl >/dev/null 2>&1 || { err "Se requiere systemd."; return 1; }
  mkdir -p "$DESTDIR"
  cat > "$SERVER_PY" <<'PYEOF'
#!/usr/bin/env python3
# Servidor BHTTP autónomo - asyncio; formato de paquetes original conservado.
import argparse, asyncio, hashlib, socket, sys
MAGIC = b"BHP1"
# Se conserva el tiempo de espera del protocolo original.
LONGPOLL = 2.0

def tune_writer(writer, rcvbuf, sndbuf, write_high, write_low):
    """Ajustes TCP opcionales; no cambian los paquetes BHTTP."""
    sock = writer.get_extra_info("socket")
    if sock is not None:
        try:
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
            if hasattr(socket, "TCP_KEEPIDLE"):
                sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPIDLE, 30)
            if hasattr(socket, "TCP_KEEPINTVL"):
                sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPINTVL, 10)
            if hasattr(socket, "TCP_KEEPCNT"):
                sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPCNT, 3)
            # 0 deja que Linux gestione automáticamente los buffers TCP.
            if rcvbuf > 0:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, rcvbuf * 1024)
            if sndbuf > 0:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, sndbuf * 1024)
        except OSError as exc:
            log("aviso: no se pudo aplicar una opción TCP: %s" % exc)
    try:
        writer.transport.set_write_buffer_limits(high=write_high, low=write_low)
    except (AttributeError, RuntimeError):
        pass
def log(msg):
    sys.stderr.write("[bhttp] %s\n" % msg); sys.stderr.flush()
def keystream(sess, mode, seq, d, n):
    base = hashlib.sha256(sess + bytes([mode]) + seq.to_bytes(8, "big") + bytes([d]))
    out = bytearray(); c = 0
    while len(out) < n:
        h = base.copy(); h.update(c.to_bytes(4, "big")); out += h.digest(); c += 1
    return bytes(out[:n])
def mask(data, sess, mode, seq, d):
    return bytes(a ^ b for a, b in zip(data, keystream(sess, mode, seq, d, len(data))))
def probe_reply(mode, size):
    n = size if (mode == 2 and size >= 10) else 10
    out = bytearray(MAGIC + bytes([1, mode]) + size.to_bytes(4, "big"))
    for i in range(10, n):
        out.append((i * 31) & 255)
    return bytes(out)
class Session:
    def __init__(self, sess, backend, tuning):
        self.sess = sess
        self.backend = backend
        self.tuning = tuning
        self.up_lock = asyncio.Lock()
        self.cond = asyncio.Condition()
        self.up_next = 0
        self.up_pending = {}
        self.down_raw = bytearray()
        self.down_chunks = {}
        self.down_assign = 0
        self.eof = False
        self.closed = False
        self.br = None
        self.bw = None
    async def connect(self):
        host, port = self.backend
        self.br, self.bw = await asyncio.open_connection(host, port, limit=self.tuning[4])
        tune_writer(self.bw, *self.tuning[:4])
        log("sesion %s: conectada al backend %s:%d" % (self.sess.hex()[:8], host, port))
        asyncio.create_task(self._reader())
    async def _reader(self):
        total = 0
        try:
            while True:
                data = await self.br.read(65536)
                if not data: break
                total += len(data)
                async with self.cond:
                    self.down_raw += data
                    self.cond.notify_all()
        except Exception as e:
            log("sesion %s: error leyendo del backend: %s" % (self.sess.hex()[:8], e))
        finally:
            log("sesion %s: el backend cerro (recibidos %d B)" % (self.sess.hex()[:8], total))
            async with self.cond:
                self.eof = True
                self.closed = True
                self.cond.notify_all()
    async def upload(self, seq, data):
        # No mantener el candado de descarga mientras drain() espera a TCP.
        async with self.up_lock:
            async with self.cond:
                if data:
                    self.up_pending[seq] = data
            while True:
                async with self.cond:
                    chunk = self.up_pending.pop(self.up_next, None)
                    if chunk is None:
                        break
                    self.up_next += 1
                try:
                    self.bw.write(chunk)
                    await self.bw.drain()
                except (ConnectionError, OSError):
                    self.closed = True
                    return
    async def download(self, seq, maxlen, deadline):
        if maxlen <= 0: maxlen = 1399
        loop = asyncio.get_running_loop()
        async with self.cond:
            while True:
                if seq < self.down_assign:
                    return self.down_chunks.get(seq, b"")
                if seq == self.down_assign:
                    if self.down_raw:
                        take = bytes(self.down_raw[:maxlen]); del self.down_raw[:maxlen]
                        self.down_chunks[self.down_assign] = take
                        self.down_assign += 1
                        self.cond.notify_all()
                        return take
                    if self.eof:
                        self.down_assign += 1
                        self.cond.notify_all()
                        return b""
                if not self.eof and loop.time() < deadline:
                    try:
                        await asyncio.wait_for(self.cond.wait(), timeout=max(0.01, deadline - loop.time()))
                    except asyncio.TimeoutError:
                        pass
                    continue
                while self.down_assign <= seq:
                    self.down_assign += 1
                self.cond.notify_all()
                return b""
    async def ack(self, seq):
        async with self.cond:
            for k in [k for k in self.down_chunks if k <= seq]:
                del self.down_chunks[k]
    async def close(self):
        async with self.cond:
            self.closed = True
            self.cond.notify_all()
        try: self.bw.close()
        except Exception: pass
class Server:
    def __init__(self, host, port, backend, tuning):
        self.host, self.port, self.backend = host, port, backend
        self.tuning = tuning
        self.sessions = {}
        self.slock = asyncio.Lock()
    async def get_session(self, sess):
        async with self.slock:
            s = self.sessions.get(sess)
            if s is None or s.closed:
                # Cada identificador de sesión conserva su propio backend.
                # No cerrar otras sesiones: eso provocaba cortes al conectar
                # otro dispositivo o al abrir conexiones paralelas.
                s = Session(sess, self.backend, self.tuning)
                await s.connect()
                self.sessions[sess] = s
                log("sesion %s: registrada (vivas: %d)" % (sess.hex()[:8], len(self.sessions)))
            return s
    async def handle(self, reader, writer):
        tune_writer(writer, *self.tuning[:4])
        try:
            while True:
                hdr = await reader.readexactly(29)
                mode = hdr[0]
                sess = hdr[1:17]
                seq = int.from_bytes(hdr[17:25], "big")
                ln = int.from_bytes(hdr[25:29], "big")
                payload = b""
                if ln and mode in (0, 1, 2, 3):
                    raw = await reader.readexactly(ln)
                    payload = mask(raw, sess, mode, seq, 0)
                if payload[:4] == MAGIC:
                    size = int.from_bytes(payload[6:10], "big") if len(payload) >= 10 else 0
                    pmode = payload[5] if len(payload) >= 6 else mode
                    body = mask(probe_reply(pmode, size), sess, mode, seq, 1)
                    writer.write(bytes([0]) + len(body).to_bytes(4, "big") + body)
                    await writer.drain()
                    continue
                s = await self.get_session(sess)
                if mode == 1:
                    await s.upload(seq, payload)
                    writer.write(bytes([0]) + (0).to_bytes(4, "big"))
                    await writer.drain()
                elif mode == 2:
                    chunk = await s.download(seq, ln if ln > 0 else 1399, asyncio.get_running_loop().time() + LONGPOLL)
                    self._send_data(writer, sess, mode, seq, chunk)
                    await writer.drain()
                elif mode == 3:
                    if len(payload) >= 6:
                        chunk_size = int.from_bytes(payload[0:4], "big"); count = payload[5]
                    else:
                        chunk_size, count = 1399, 1
                    if chunk_size <= 0: chunk_size = 1399
                    if count <= 0: count = 1
                    deadline = asyncio.get_running_loop().time() + LONGPOLL
                    for i in range(count):
                        chunk = await s.download(seq + i, chunk_size, deadline)
                        self._send_data(writer, sess, mode, seq + i, chunk)
                    await writer.drain()
                elif mode == 4:
                    await s.ack(seq)
                    writer.write(bytes([0]) + (0).to_bytes(4, "big"))
                    await writer.drain()
                else:
                    return
        except (asyncio.IncompleteReadError, ConnectionError, OSError):
            pass
        except Exception as e:
            log("handle: %r" % e)
        finally:
            try: writer.close()
            except Exception: pass
    def _send_data(self, writer, sess, mode, seq, data):
        real = len(data)
        masked = mask(data, sess, mode, seq, 1) if data else b""
        body = real.to_bytes(4, "big") + masked
        writer.write(bytes([2]) + len(body).to_bytes(4, "big") + body)
    async def serve(self):
        srv = await asyncio.start_server(
            self.handle, self.host, self.port,
            backlog=512, limit=self.tuning[4], reuse_address=True
        )
        print("BHTTP escuchando en %s:%d -> backend %s:%d" % (self.host, self.port, self.backend[0], self.backend[1]), flush=True)
        async with srv:
            await srv.serve_forever()
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--backend-host", default="127.0.0.1")
    ap.add_argument("--backend-port", type=int, default=22)
    ap.add_argument("--rcvbuf-kb", type=int, default=0)
    ap.add_argument("--sndbuf-kb", type=int, default=0)
    ap.add_argument("--write-high-kb", type=int, default=256)
    ap.add_argument("--stream-limit-kb", type=int, default=256)
    a = ap.parse_args()
    if min(a.rcvbuf_kb, a.sndbuf_kb) < 0 or not 16 <= a.write_high_kb <= 16384 or not 16 <= a.stream_limit_kb <= 16384:
        ap.error("valores de búfer fuera de rango")
    tuning = (a.rcvbuf_kb, a.sndbuf_kb, a.write_high_kb * 1024,
              (a.write_high_kb // 4) * 1024, a.stream_limit_kb * 1024)
    asyncio.run(Server(a.host, a.port, (a.backend_host, a.backend_port), tuning).serve())
if __name__ == "__main__":
    main()
PYEOF
  chmod 755 "$SERVER_PY"
  python3 -m py_compile "$SERVER_PY"
  save_config
  write_service
  systemctl restart "$SERVICE"
  sleep 2
  if systemctl is-active --quiet "$SERVICE"; then
    ok "Servidor BHTTP instalado y activo."
    show_config
  else
    err "No se pudo iniciar BHTTP. Últimos registros:"
    journalctl -u "$SERVICE" -n 30 --no-pager || true
    return 1
  fi
}

show_config() {
  echo "Puerto BHTTP       : $BHTTP_PORT"
  echo "Backend SSH        : 127.0.0.1:$BACKEND_PORT"
  echo "Buffer recepción   : ${RCVBUF_KB} KB (0 = automático)"
  echo "Buffer envío       : ${SNDBUF_KB} KB (0 = automático)"
  echo "Buffer escritura   : ${WRITE_HIGH_KB} KB"
  echo "Límite de flujo    : ${STREAM_LIMIT_KB} KB"
  echo "Estado             : $(systemctl is-active "$SERVICE" 2>/dev/null || echo no-instalado)"
}

change_ports() {
  local p
  banner; echo "PUERTOS"; line
  read -r -p "Nuevo puerto BHTTP [$BHTTP_PORT]: " p
  if [[ -n "$p" ]]; then valid_port "$p" || { err "Puerto inválido."; read -r -p 'Enter...'; return; }; BHTTP_PORT=$p; fi
  read -r -p "Nuevo puerto backend SSH [$BACKEND_PORT]: " p
  if [[ -n "$p" ]]; then valid_port "$p" || { err "Puerto inválido."; read -r -p 'Enter...'; return; }; BACKEND_PORT=$p; fi
  [[ "$BHTTP_PORT" != "$BACKEND_PORT" ]] || { err "Los puertos público y backend no deben ser iguales."; read -r -p 'Enter...'; return; }
  apply_config || true
  read -r -p 'Enter para continuar...'
}

change_buffers() {
  local v
  banner; echo "RENDIMIENTO Y BÚFERES"; line
  echo "Usa 0 para búferes TCP automáticos. Rango permitido: 0–16384 KB."
  read -r -p "Recepción TCP [$RCVBUF_KB]: " v; [[ -z "$v" ]] || { valid_buffer "$v" || { err "Valor inválido."; read -r -p 'Enter...'; return; }; RCVBUF_KB=$v; }
  read -r -p "Envío TCP [$SNDBUF_KB]: " v; [[ -z "$v" ]] || { valid_buffer "$v" || { err "Valor inválido."; read -r -p 'Enter...'; return; }; SNDBUF_KB=$v; }
  read -r -p "Escritura asyncio KB [$WRITE_HIGH_KB]: " v; [[ -z "$v" ]] || { valid_buffer "$v" && (( v >= 16 )) || { err "Usa 16–16384 KB."; read -r -p 'Enter...'; return; }; WRITE_HIGH_KB=$v; }
  read -r -p "Límite de flujo KB [$STREAM_LIMIT_KB]: " v; [[ -z "$v" ]] || { valid_buffer "$v" && (( v >= 16 )) || { err "Usa 16–16384 KB."; read -r -p 'Enter...'; return; }; STREAM_LIMIT_KB=$v; }
  apply_config || true
  warn "Un búfer mayor no garantiza menor ping; compara latencia y pérdida bajo carga."
  read -r -p 'Enter para continuar...'
}

service_menu() {
  local choice
  while true; do
    banner; echo "SERVICIO"; line
    echo "Estado: $(systemctl is-active "$SERVICE" 2>/dev/null || echo no-instalado)"
    echo "1) Iniciar   2) Detener   3) Reiniciar   4) Estado detallado"
    echo "5) Ver logs en vivo   0) Volver"; line
    read -r -p 'Opción: ' choice
    case "$choice" in
      1) systemctl start "$SERVICE" && ok "Iniciado." || err "No se pudo iniciar."; sleep 1;;
      2) systemctl stop "$SERVICE" && ok "Detenido." || err "No se pudo detener."; sleep 1;;
      3) systemctl restart "$SERVICE" && ok "Reiniciado." || err "No se pudo reiniciar."; sleep 1;;
      4) systemctl status "$SERVICE" --no-pager || true; read -r -p 'Enter...';;
      5) echo "Ctrl+C para salir de los logs."; journalctl -u "$SERVICE" -f;;
      0) return;;
      *) warn "Opción no válida."; sleep 1;;
    esac
  done
}

user_create() {
  local username password pubkey comment home
  banner; echo "CREAR USUARIO SSH"; line
  read -r -p "Nombre de usuario: " username
  [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { err "Nombre inválido (usa minúsculas, números, _ o -)."; read -r -p 'Enter...'; return; }
  if id "$username" >/dev/null 2>&1; then err "El usuario ya existe."; read -r -p 'Enter...'; return; fi
  read -r -s -p "Contraseña (vacío = generar): " password; echo
  if [[ -z "$password" ]]; then password="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 18 || true)"; fi
  useradd -m -s /bin/bash "$username"
  printf '%s:%s\n' "$username" "$password" | chpasswd
  echo; ok "Usuario SSH creado: $username"
  echo "Contraseña: $password"
  echo
  read -r -p "¿Agregar clave pública SSH para vincular un dispositivo? [s/N]: " answer
  if [[ "$answer" =~ ^[sS]$ ]]; then
    read -r -p "Pega la clave pública SSH (ssh-ed25519/ssh-rsa): " pubkey
    if [[ "$pubkey" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+)[[:space:]] ]]; then
      home="$(getent passwd "$username" | cut -d: -f6)"
      install -d -m 700 -o "$username" -g "$username" "$home/.ssh"
      printf '%s panel-device\n' "$pubkey" >> "$home/.ssh/authorized_keys"
      chown "$username:$username" "$home/.ssh/authorized_keys"
      chmod 600 "$home/.ssh/authorized_keys"
      if command -v ssh-keygen >/dev/null 2>&1; then
        printf '%s\n' "$pubkey" | ssh-keygen -lf - 2>/dev/null || true
      fi
      ok "Clave añadida. La huella identifica la clave/dispositivo, no el HWID físico."
    else
      err "Formato de clave pública no reconocido; el usuario sigue creado con contraseña."
    fi
  fi
  read -r -p 'Enter para continuar...'
}

user_menu() {
  local choice username password
  while true; do
    banner; echo "USUARIOS SSH"; line
    echo "1) Crear usuario SSH (opcional: clave por dispositivo)"
    echo "2) Listar usuarios locales"
    echo "3) Cambiar contraseña"
    echo "4) Eliminar usuario"
    echo "0) Volver"; line
    read -r -p 'Opción: ' choice
    case "$choice" in
      1) user_create;;
      2) awk -F: '$3 >= 1000 && $1 != "nobody" {printf "%-24s UID %s\\n", $1, $3}' /etc/passwd; read -r -p 'Enter...';;
      3) read -r -p 'Usuario: ' username; id "$username" >/dev/null 2>&1 || { err "Usuario inexistente."; read -r -p 'Enter...'; continue; }; read -r -s -p 'Nueva contraseña: ' password; echo; printf '%s:%s\n' "$username" "$password" | chpasswd && ok "Contraseña actualizada."; read -r -p 'Enter...';;
      4) read -r -p 'Usuario a eliminar: ' username; if id "$username" >/dev/null 2>&1 && [[ "$username" != root ]]; then userdel -r "$username" && ok "Usuario eliminado."; else err "Usuario inválido o protegido."; fi; read -r -p 'Enter...';;
      0) return;;
      *) warn "Opción no válida."; sleep 1;;
    esac
  done
}

diagnostics() {
  banner; echo "DIAGNÓSTICO RÁPIDO"; line
  if systemctl is-active --quiet "$SERVICE"; then ok "Servicio BHTTP activo."; else err "Servicio BHTTP detenido o no instalado."; fi
  if command -v ss >/dev/null 2>&1; then
    ss -ltn | awk -v p=":$BHTTP_PORT" '$4 ~ p"$" {found=1} END {if(found) print "Puerto BHTTP en escucha: OK"; else print "Puerto BHTTP no aparece en escucha."}'
  fi
  if timeout 3 bash -c "</dev/tcp/127.0.0.1/$BACKEND_PORT" 2>/dev/null; then
    ok "Backend TCP 127.0.0.1:$BACKEND_PORT responde."
  else
    warn "No se pudo conectar al backend 127.0.0.1:$BACKEND_PORT. Comprueba SSH y su puerto."
  fi
  echo
  echo "Configuración actual:"; show_config
  echo
  warn "Esta prueba es local en la VPS; no mide el ping ni el rendimiento entre tu móvil y la VPS."
  read -r -p 'Enter para continuar...'
}

uninstall_panel() {
  local answer
  banner; read -r -p "¿Desinstalar el servicio BHTTP y sus archivos? [s/N]: " answer
  [[ "$answer" =~ ^[sS]$ ]] || return
  systemctl disable --now "$SERVICE" 2>/dev/null || true
  rm -f "$UNIT"; rm -rf "$DESTDIR"; rm -f "$CONF"
  systemctl daemon-reload
  ok "BHTTP desinstalado. Los usuarios SSH del sistema no se eliminan."
  read -r -p 'Enter para continuar...'
}

main_menu() {
  local choice
  while true; do
    banner
    printf "  Estado: %b\n" "$(systemctl is-active "$SERVICE" 2>/dev/null || echo no-instalado)"
    printf "  BHTTP: %s   Backend: %s\n" "$BHTTP_PORT" "$BACKEND_PORT"
    line
    echo "  1) Instalar / reparar servidor"
    echo "  2) Puertos de conexión y backend"
    echo "  3) Búferes y rendimiento"
    echo "  4) Usuarios SSH y dispositivos (claves)"
    echo "  5) Control del servicio y logs"
    echo "  6) Diagnóstico de puertos y servicio"
    echo "  7) Ver configuración actual"
    echo "  8) Desinstalar BHTTP"
    echo "  0) Salir"
    line
    read -r -p '  Selecciona una opción: ' choice
    case "$choice" in
      1) install_server; read -r -p 'Enter para continuar...';;
      2) change_ports;;
      3) change_buffers;;
      4) user_menu;;
      5) service_menu;;
      6) diagnostics;;
      7) banner; show_config; echo; echo "TCP Keepalive y TCP_NODELAY están habilitados en el servidor."; read -r -p 'Enter para continuar...';;
      8) uninstall_panel;;
      0) echo "Panel cerrado."; exit 0;;
      *) warn "Opción no válida."; sleep 1;;
    esac
  done
}

need_root
load_config
main_menu
