#!/usr/bin/env bash
# Instalador sencillo del servidor BHTTP
set -Eeuo pipefail

DESTDIR="/usr/local/lib/bhttp"
SERVER_PY="$DESTDIR/bhttp-server.py"
UNIT="/etc/systemd/system/bhttp.service"
SERVICE="bhttp"

error() { echo "ERROR: $*" >&2; }
need_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    error "Ejecuta como root: sudo bash $0"
    exit 1
  fi
}
valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}
port_in_use() {
  if command -v ss >/dev/null 2>&1; then
    ss -H -ltn 2>/dev/null | awk '{print $4}' |
      grep -Eq "(:|\\])$1$"
  else
    return 1
  fi
}
install_server() {
  local bhttp_port backend_port pybin
  echo "Instalación BHTTP"
  read -r -p "Puerto BHTTP público: " bhttp_port
  if ! valid_port "$bhttp_port"; then error "Puerto BHTTP inválido."; return 1; fi
  if port_in_use "$bhttp_port"; then error "El puerto $bhttp_port ya está ocupado."; return 1; fi

  read -r -p "Puerto backend SSH [22]: " backend_port
  backend_port="${backend_port:-22}"
  if ! valid_port "$backend_port"; then error "Puerto backend inválido."; return 1; fi
  if [[ "$bhttp_port" == "$backend_port" ]]; then
    error "El puerto BHTTP y el backend no pueden ser iguales."
    return 1
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    echo "Instalando Python 3..."
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update
      apt-get install -y python3
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y python3
    elif command -v yum >/dev/null 2>&1; then
      yum install -y python3
    else
      error "Instala Python 3 manualmente y vuelve a ejecutar."
      return 1
    fi
  fi
  if ! command -v systemctl >/dev/null 2>&1; then
    error "Este instalador requiere systemd."
    return 1
  fi

  mkdir -p "$DESTDIR"
  cat > "$SERVER_PY" <<'PYEOF'
#!/usr/bin/env python3
# Servidor BHTTP autónomo (Null) - asyncio
import argparse, asyncio, hashlib, struct, sys
MAGIC = b"BHP1"
LONGPOLL = 2.0
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
    def __init__(self, sess, backend):
        self.sess = sess
        self.backend = backend
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
        self.br, self.bw = await asyncio.open_connection(host, port)
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
                self.cond.notify_all()
    async def upload(self, seq, data):
        async with self.cond:
            if data:
                self.up_pending[seq] = data
            while self.up_next in self.up_pending:
                chunk = self.up_pending.pop(self.up_next)
                try:
                    self.bw.write(chunk)
                    await self.bw.drain()
                except Exception:
                    self.closed = True
                self.up_next += 1
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
    def __init__(self, host, port, backend):
        self.host, self.port, self.backend = host, port, backend
        self.sessions = {}
        self.slock = asyncio.Lock()
    async def get_session(self, sess):
        async with self.slock:
            s = self.sessions.get(sess)
            if s is None or s.closed:
                for old_sid, old in list(self.sessions.items()):
                    if old_sid != sess:
                        await old.close()
                        del self.sessions[old_sid]
                s = Session(sess, self.backend)
                await s.connect()
                self.sessions[sess] = s
                log("sesion %s: registrada (vivas: %d)" % (sess.hex()[:8], len(self.sessions)))
            return s
    async def handle(self, reader, writer):
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
        srv = await asyncio.start_server(self.handle, self.host, self.port, backlog=512)
        print("BHTTP escuchando en %s:%d -> backend %s:%d" % (self.host, self.port, self.backend[0], self.backend[1]), flush=True)
        async with srv:
            await srv.serve_forever()
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--backend-host", default="127.0.0.1")
    ap.add_argument("--backend-port", type=int, default=22)
    a = ap.parse_args()
    asyncio.run(Server(a.host, a.port, (a.backend_host, a.backend_port)).serve())
if __name__ == "__main__":
    main()
PYEOF
  chmod 755 "$SERVER_PY"
  python3 -m py_compile "$SERVER_PY"

  pybin="$(command -v python3)"
  cat > "$UNIT" <<EOF
[Unit]
Description=BHTTP Server
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=$pybin $SERVER_PY --host 0.0.0.0 --port $bhttp_port --backend-host 127.0.0.1 --backend-port $backend_port
Restart=always
RestartSec=5
TimeoutStopSec=15
KillSignal=SIGINT
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "$SERVICE" >/dev/null
  systemctl restart "$SERVICE"
  sleep 2

  if systemctl is-active --quiet "$SERVICE"; then
    echo
    echo "Instalación completada."
    echo "Puerto BHTTP: $bhttp_port"
    echo "Backend SSH: 127.0.0.1:$backend_port"
    echo "Servicio: activo (inicio automático habilitado)"
    echo
    echo "Asegúrate de permitir el puerto BHTTP en el firewall de la VPS/proveedor."
  else
    error "BHTTP no pudo iniciar. Últimos registros:"
    journalctl -u "$SERVICE" -n 30 --no-pager
    return 1
  fi
}
remove_server() {
  read -r -p "¿Desinstalar BHTTP? [s/N]: " answer
  [[ "$answer" =~ ^[sS]$ ]] || return 0
  systemctl disable --now "$SERVICE" 2>/dev/null || true
  rm -f "$UNIT"
  rm -rf "$DESTDIR"
  systemctl daemon-reload
  echo "BHTTP desinstalado."
}
status_server() {
  systemctl status "$SERVICE" --no-pager || true
}
logs_server() {
  journalctl -u "$SERVICE" -f
}
main() {
  need_root
  case "${1:-install}" in
    install) install_server ;;
    uninstall) remove_server ;;
    status) status_server ;;
    logs) logs_server ;;
    restart) systemctl restart "$SERVICE" ;;
    stop) systemctl stop "$SERVICE" ;;
    start) systemctl start "$SERVICE" ;;
    *)
      echo "Uso: bash $0 [install|uninstall|status|logs|restart|start|stop]"
      exit 2
      ;;
  esac
}
main "$@"
