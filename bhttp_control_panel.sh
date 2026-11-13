#!/usr/bin/env bash
# BHTTP Control Panel — interfaz profesional sobre la versión estable.
# El servidor Python y el protocolo se mantienen iguales a bhttp_installer_estable.sh.
set -Eeuo pipefail

APP="BHTTP CONTROL PANEL"
DESTDIR="/usr/local/lib/bhttp"
SERVER_PY="$DESTDIR/bhttp-server.py"
UNIT="/etc/systemd/system/bhttp.service"
CONF_DIR="/etc/bhttp"
CONF="$CONF_DIR/bhttp.conf"
SERVICE="bhttp"

BHTTP_PORT=8080
BACKEND_PORT=22
RCVBUF_KB=0
SNDBUF_KB=0
WRITE_HIGH_KB=256
STREAM_LIMIT_KB=256

RESET='\033[0m'; BOLD='\033[1m'; DIM='\033[2m'
CYAN='\033[36m'; BLUE='\033[34m'; GREEN='\033[32m'
YELLOW='\033[33m'; RED='\033[31m'; WHITE='\033[97m'; MAGENTA='\033[35m'

paint(){ printf '%b%s%b' "$1" "$2" "$RESET"; }
line(){ printf '%b\n' "${DIM}  ─────────────────────────────────────────────────────────────${RESET}"; }
ok(){ paint "$GREEN" "  ✓ $*"; printf '\n'; }
info(){ paint "$CYAN" "  • $*"; printf '\n'; }
warn(){ paint "$YELLOW" "  ! $*"; printf '\n'; }
err(){ paint "$RED" "  ✗ $*" >&2; printf '\n' >&2; }
pause(){ echo; read -r -p "  Presiona Enter para continuar..." _; }
need_root(){ [[ $(id -u) -eq 0 ]] || { err "Ejecuta con sudo: sudo bash $0"; exit 1; }; }
valid_port(){ [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
valid_buffer(){ [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 <= 16384 )); }

banner(){
  clear 2>/dev/null || true
  printf '%b\n' "${CYAN}${BOLD}  ____  _   _ _____ _____ ____  ${RESET}"
  printf '%b\n' "${BLUE}${BOLD} | __ )| | | |_   _|_   _|  _ \\ ${RESET}"
  printf '%b\n' "${CYAN}${BOLD} |  _ \\| |_| | | |   | | | |_) |${RESET}"
  printf '%b\n' "${BLUE}${BOLD} | |_) |  _  | | |   | | |  __/ ${RESET}"
  printf '%b\n' "${CYAN}${BOLD} |____/|_| |_| |_|   |_| |_|    ${RESET}"
  printf '%b\n' "  ${WHITE}${BOLD}BHTTP CONTROL PANEL${RESET} ${DIM}· administración estable${RESET}"
  local state="no instalado"
  if command -v systemctl >/dev/null 2>&1 && [[ -f "$UNIT" ]]; then state="$(systemctl is-active "$SERVICE" 2>/dev/null || true)"; fi
  printf '  Estado: '
  case "$state" in active) paint "$GREEN" "● ACTIVO";; failed) paint "$RED" "● ERROR";; *) paint "$YELLOW" "● $state";; esac
  printf '   Puerto: %s   Backend: %s\n' "${BHTTP_PORT:-—}" "${BACKEND_PORT:-22}"
  line
}

load_config(){
  mkdir -p "$CONF_DIR"
  if [[ -f "$CONF" ]]; then
    # Archivo escrito por este panel; únicamente contiene números.
    source "$CONF"
  fi
  : "${BHTTP_PORT:=8080}" "${BACKEND_PORT:=22}" "${RCVBUF_KB:=0}" "${SNDBUF_KB:=0}" "${WRITE_HIGH_KB:=256}" "${STREAM_LIMIT_KB:=256}"
}
save_config(){
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

write_service(){
  local pybin; pybin="$(command -v python3)"
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
apply_config(){
  save_config
  if [[ ! -f "$SERVER_PY" ]]; then warn "Configuración guardada. Instala BHTTP primero."; return 0; fi
  write_service
  systemctl restart "$SERVICE"
  sleep 2
  if systemctl is-active --quiet "$SERVICE"; then ok "Configuración aplicada y servicio activo."; else err "No arrancó. Revisa Diagnóstico y registros."; return 1; fi
}

install_server(){
  if ! command -v python3 >/dev/null 2>&1; then
    info "Instalando Python 3..."
    if command -v apt-get >/dev/null 2>&1; then apt-get update && apt-get install -y python3
    elif command -v dnf >/dev/null 2>&1; then dnf install -y python3
    elif command -v yum >/dev/null 2>&1; then yum install -y python3
    else err "Instala Python 3 manualmente."; return 1; fi
  fi
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
  write_service
  systemctl restart "$SERVICE"
  sleep 2
  if systemctl is-active --quiet "$SERVICE"; then
    save_config
    ok "Servidor BHTTP instalado y activo."
    info "BHTTP: $BHTTP_PORT  |  Backend SSH: 127.0.0.1:$BACKEND_PORT"
  else
    err "BHTTP no pudo iniciar. Últimos registros:"
    journalctl -u "$SERVICE" -n 25 --no-pager || true
    return 1
  fi
}

configure_ports(){
  local v
  echo; paint "$WHITE$BOLD" "  CONFIGURACIÓN DE PUERTOS"; echo; line
  read -r -p "  Puerto público BHTTP [$BHTTP_PORT]: " v; v="${v:-$BHTTP_PORT}"
  valid_port "$v" || { err "Puerto público inválido."; return; }; BHTTP_PORT=$((10#$v))
  read -r -p "  Puerto backend SSH [$BACKEND_PORT]: " v; v="${v:-$BACKEND_PORT}"
  valid_port "$v" || { err "Puerto backend inválido."; return; }; BACKEND_PORT=$((10#$v))
  [[ "$BHTTP_PORT" != "$BACKEND_PORT" ]] || { err "Los puertos público y backend no deben coincidir."; return; }
  apply_config
}
configure_buffers(){
  local v
  echo; paint "$WHITE$BOLD" "  AJUSTES DE RENDIMIENTO"; echo; line
  info "Valores en KB. TCP 0 = automático; escritura y stream: 16–16384 KB."
  read -r -p "  Buffer TCP recepción [$RCVBUF_KB]: " v; RCVBUF_KB="${v:-$RCVBUF_KB}"
  valid_buffer "$RCVBUF_KB" || { err "Valor de recepción inválido."; return; }
  read -r -p "  Buffer TCP envío [$SNDBUF_KB]: " v; SNDBUF_KB="${v:-$SNDBUF_KB}"
  valid_buffer "$SNDBUF_KB" || { err "Valor de envío inválido."; return; }
  read -r -p "  Buffer escritura asyncio [$WRITE_HIGH_KB]: " v; WRITE_HIGH_KB="${v:-$WRITE_HIGH_KB}"
  [[ "$WRITE_HIGH_KB" =~ ^[0-9]+$ ]] && (( WRITE_HIGH_KB >= 16 && WRITE_HIGH_KB <= 16384 )) || { err "Valor de escritura fuera de rango."; return; }
  read -r -p "  Límite de stream [$STREAM_LIMIT_KB]: " v; STREAM_LIMIT_KB="${v:-$STREAM_LIMIT_KB}"
  [[ "$STREAM_LIMIT_KB" =~ ^[0-9]+$ ]] && (( STREAM_LIMIT_KB >= 16 && STREAM_LIMIT_KB <= 16384 )) || { err "Límite de stream fuera de rango."; return; }
  apply_config
}

users_menu(){
  local op u p key comment home
  while true; do
    banner; paint "$WHITE$BOLD" "  ADMINISTRACIÓN SSH"; echo; line
    echo "  [1] Crear usuario SSH con contraseña"
    echo "  [2] Autorizar clave pública SSH (identificación por huella)"
    echo "  [3] Listar usuarios locales"
    echo "  [4] Cambiar contraseña SSH"
    echo "  [5] Eliminar usuario"
    echo "  [0] Volver"; line
    read -r -p "  Selecciona: " op
    case "$op" in
      1)
        read -r -p "  Usuario: " u
        [[ "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { err "Nombre no válido."; pause; continue; }
        if id "$u" >/dev/null 2>&1; then warn "El usuario ya existe."; else useradd -m -s /bin/bash "$u" || { err "No se pudo crear."; pause; continue; }; fi
        read -r -s -p "  Contraseña: " p; echo
        [[ -n "$p" ]] || { err "Contraseña vacía."; pause; continue; }
        printf '%s:%s\n' "$u" "$p" | chpasswd && ok "Usuario SSH preparado." || err "No se pudo establecer la contraseña."
        unset p; pause ;;
      2)
        read -r -p "  Usuario existente: " u
        id "$u" >/dev/null 2>&1 || { err "Primero crea el usuario."; pause; continue; }
        read -r -p "  Etiqueta del dispositivo (ej. movil-1): " comment
        read -r -p "  Pega la clave pública SSH completa: " key
        [[ "$key" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+)[[:space:]] ]] || { err "Formato de clave pública no reconocido."; pause; continue; }
        home="$(getent passwd "$u" | cut -d: -f6)"
        install -d -m 700 -o "$u" -g "$u" "$home/.ssh"
        printf '%s %s\n' "$key" "${comment//[^a-zA-Z0-9_.-]/_}" >> "$home/.ssh/authorized_keys"
        chown "$u:$u" "$home/.ssh/authorized_keys"; chmod 600 "$home/.ssh/authorized_keys"
        ok "Clave autorizada. La huella identifica la clave, no el hardware físico."; pause ;;
      3) awk -F: '$3>=1000 && $1!="nobody" {printf "  %-24s UID %s\\n",$1,$3}' /etc/passwd; pause ;;
      4) read -r -p "  Usuario: " u; id "$u" >/dev/null 2>&1 || { err "Usuario inexistente."; pause; continue; }
         read -r -s -p "  Nueva contraseña: " p; echo
         [[ -n "$p" ]] && printf '%s:%s\n' "$u" "$p" | chpasswd && ok "Contraseña actualizada." || err "No se pudo actualizar."; unset p; pause ;;
      5) read -r -p "  Usuario a eliminar: " u
         [[ "$u" != root && "$u" != "${SUDO_USER:-}" ]] || { err "No se permite eliminar root ni el usuario administrador actual."; pause; continue; }
         if id "$u" >/dev/null 2>&1; then userdel -r "$u" && ok "Usuario eliminado." || err "No se pudo eliminar."; else warn "Usuario no encontrado."; fi; pause ;;
      0) return ;;
      *) warn "Opción no válida."; sleep 1 ;;
    esac
  done
}

service_menu(){
  local op
  while true; do
    banner; paint "$WHITE$BOLD" "  CONTROL DEL SERVICIO"; echo; line
    echo "  [1] Iniciar"; echo "  [2] Detener"; echo "  [3] Reiniciar"; echo "  [4] Estado detallado"; echo "  [5] Ver registros en vivo"; echo "  [0] Volver"; line
    read -r -p "  Selecciona: " op
    case "$op" in
      1) systemctl start "$SERVICE" && ok "Servicio iniciado." || err "No se pudo iniciar."; pause ;;
      2) systemctl stop "$SERVICE" && ok "Servicio detenido." || err "No se pudo detener."; pause ;;
      3) systemctl restart "$SERVICE" && ok "Servicio reiniciado." || err "No se pudo reiniciar."; pause ;;
      4) systemctl status "$SERVICE" --no-pager || true; pause ;;
      5) echo "  Ctrl+C para volver."; journalctl -u "$SERVICE" -f || true ;;
      0) return ;;
      *) warn "Opción no válida."; sleep 1 ;;
    esac
  done
}

diagnostics(){
  banner; paint "$WHITE$BOLD" "  INFORMACIÓN Y DIAGNÓSTICO"; echo; line
  echo "  BHTTP: $BHTTP_PORT"; echo "  Backend: 127.0.0.1:$BACKEND_PORT"
  echo "  Buffer TCP RX: $RCVBUF_KB KB"; echo "  Buffer TCP TX: $SNDBUF_KB KB"
  echo "  Escritura asyncio: $WRITE_HIGH_KB KB"; echo "  Stream limit: $STREAM_LIMIT_KB KB"
  echo; systemctl is-active "$SERVICE" 2>/dev/null || true
  echo; ss -ltnp 2>/dev/null | grep -E ":(${BHTTP_PORT}|${BACKEND_PORT})\\b" || true
  echo; journalctl -u "$SERVICE" -n 15 --no-pager 2>/dev/null || true
  pause
}

uninstall_server(){
  local answer
  read -r -p "  ¿Desinstalar BHTTP y su configuración? [s/N]: " answer
  [[ "$answer" =~ ^[sS]$ ]] || return
  systemctl disable --now "$SERVICE" 2>/dev/null || true
  rm -f "$UNIT"; rm -rf "$DESTDIR"; rm -f "$CONF"
  systemctl daemon-reload
  ok "BHTTP desinstalado. Los usuarios SSH del sistema no se eliminan."
  pause
}

main_menu(){
  local op
  while true; do
    banner
    printf '%b\n' "  ${WHITE}${BOLD}MENÚ PRINCIPAL${RESET}"
    echo "  [1] Instalar / reinstalar servidor"
    echo "  [2] Cambiar puertos BHTTP / backend SSH"
    echo "  [3] Ajustar búferes y rendimiento"
    echo "  [4] Administrar usuarios SSH y claves de dispositivo"
    echo "  [5] Control del servicio"
    echo "  [6] Diagnóstico e información"
    echo "  [7] Desinstalar BHTTP"
    echo "  [0] Salir"; line
    read -r -p "  Selecciona una opción: " op
    case "$op" in
      1) install_server; pause ;;
      2) configure_ports; pause ;;
      3) configure_buffers; pause ;;
      4) users_menu ;;
      5) service_menu ;;
      6) diagnostics ;;
      7) uninstall_server ;;
      0) clear 2>/dev/null || true; echo "BHTTP Control Panel cerrado."; exit 0 ;;
      *) warn "Opción no válida."; sleep 1 ;;
    esac
  done
}

need_root
load_config
main_menu
