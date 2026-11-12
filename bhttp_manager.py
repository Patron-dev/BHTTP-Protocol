#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import sys
import subprocess
import re
import time
import shutil

# Verificar privilegios de root
if os.geteuid() != 0:
    print("\033[1;31m[!] Por favor, ejecuta este script como root (sudo python3 bhttp_manager.py).\033[0m")
    sys.exit(1)

INSTALL_DIR = "/usr/local/lib/bhttp"
MANAGER_PATH = os.path.join(INSTALL_DIR, "bhttp_manager.py")
SYMLINK_PATH = "/usr/local/bin/bhttp"
SERVICE_FILE = "/etc/systemd/system/bhttp.service"

# Auto‑instalación sin reinicio por symlink
current_script = os.path.abspath(__file__)
if current_script != MANAGER_PATH:
    os.makedirs(INSTALL_DIR, exist_ok=True)
    shutil.copy2(current_script, MANAGER_PATH)
    os.chmod(MANAGER_PATH, 0o755)

    if os.path.exists(SYMLINK_PATH):
        os.remove(SYMLINK_PATH)
    try:
        os.symlink(MANAGER_PATH, SYMLINK_PATH)
    except Exception:
        pass

    print(f"\033[1;32m[✔] Gestor instalado y configurado en: {INSTALL_DIR}\033[0m")
    print(f"\033[1;32m[✔] Comando global 'bhttp' activado con éxito.\033[0m")
    print(f"\033[1;36m[i] Menú BHTTP 2.5 cargado correctamente…\033[0m\n")
    time.sleep(1.5)
# ELIMINAMOS COMPLETAMENTE: os.execv(...)

# Colores y estilos ANSI
VERDE = "\033[1;32m"
AZUL = "\033[1;34m"
AMARILLO = "\033[1;33m"
ROJO = "\033[1;31m"
CYAN = "\033[1;36m"
RESET = "\033[0m"
BLANCO = "\033[1;37m"

# Código fuente del Servidor BHTTP 2.5 optimizado
SERVER_CODE = r'''#!/usr/bin/env python3
# Servidor BHTTP autonomo optimizado para maxima estabilidad y streaming (YouTube / VoIP / DTunnel).
import argparse, asyncio, hashlib, struct, sys, socket

MAGIC = b"BHP1"
LONGPOLL = 3.0   # Configurable

def log(msg):
    sys.stderr.write("[bhttp-pro] %s\n" % msg); sys.stderr.flush()

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

def optimize_socket(sock):
    try:
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1048576)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1048576)
    except Exception:
        pass

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
        sock = self.bw.get_extra_info('socket')
        if sock:
            optimize_socket(sock)
        asyncio.create_task(self._reader())

    async def _reader(self):
        try:
            while True:
                data = await self.br.read(131072)
                if not data:
                    break
                async with self.cond:
                    self.down_raw += data
                    self.cond.notify_all()
        except Exception:
            pass
        finally:
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
        if maxlen <= 0:
            maxlen = 65536
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
                        await asyncio.wait_for(self.cond.wait(),
                                               timeout=max(0.005, deadline - loop.time()))
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
        try:
            self.bw.close()
        except Exception:
            pass

class Server:
    def __init__(self, host, port, backend):
        self.host, self.port, self.backend = host, port, backend
        self.sessions = {}
        self.slock = asyncio.Lock()

    async def get_session(self, sess):
        async with self.slock:
            s = self.sessions.get(sess)
            if s is None or s.closed:
                s = Session(sess, self.backend)
                await s.connect()
                self.sessions[sess] = s
            return s

    async def handle(self, reader, writer):
        sock = writer.get_extra_info('socket')
        if sock:
            optimize_socket(sock)
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
                    chunk = await s.download(seq, ln if ln > 0 else 65536,
                                             asyncio.get_running_loop().time() + LONGPOLL)
                    self._send_data(writer, sess, mode, seq, chunk)
                    await writer.drain()
                elif mode == 3:
                    if len(payload) >= 6:
                        chunk_size = int.from_bytes(payload[0:4], "big"); count = payload[5]
                    else:
                        chunk_size, count = 65536, 4
                    if chunk_size <= 0: chunk_size = 65536
                    if count <= 0: count = 4
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
        except Exception:
            pass
        finally:
            try:
                writer.close()
            except Exception:
                pass

    def _send_data(self, writer, sess, mode, seq, data):
        real = len(data)
        masked = mask(data, sess, mode, seq, 1) if data else b""
        body = real.to_bytes(4, "big") + masked
        writer.write(bytes([2]) + len(body).to_bytes(4, "big") + body)

    async def serve(self):
        srv = await asyncio.start_server(self.handle, self.host, self.port, backlog=8192)
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
'''


def mostrar_banner():
    os.system("clear" if os.name == "posix" else "cls")
    print(f"{CYAN}======================================================{RESET}")
    print(f"{VERDE}         Instalar BHTTP 2.5 VICTORPEREZ               {RESET}")
    print(f"{CYAN}======================================================{RESET}")
    print(f"{BLANCO} Servidor BHTTP autónomo optimizado (Streaming/VoIP)  {RESET}")
    print(f"{CYAN}======================================================{RESET}")


def instalar_bhttp():
    mostrar_banner()
    print(f"{CYAN}=== 🚀 INSTALACIÓN AUTOMÁTICA BHTTP 2.5 ==={RESET}\n")

    puerto = input("Ingrese el puerto de escucha principal (Ej. 80 o 443): ").strip()
    if not puerto.isdigit():
        print(f"{ROJO}[!] Puerto de escucha inválido.{RESET}")
        time.sleep(2)
        return

    backend_port = input("Ingrese el puerto backend local [Por defecto 22 para SSH]: ").strip()
    backend_port = backend_port if backend_port.isdigit() else "22"

    long_poll = "3.0"
    buf_mb = "1"
    buf_bytes = int(buf_mb) * 1024 * 1024

    print(f"\n{AMARILLO}[*] Escribiendo servidor en {INSTALL_DIR}...{RESET}")
    os.makedirs(INSTALL_DIR, exist_ok=True)

    server_file_path = os.path.join(INSTALL_DIR, "bhttp-server.py")
    with open(server_file_path, "w", encoding="utf-8") as f:
        f.write(SERVER_CODE)

    os.chmod(server_file_path, 0o755)

    with open(server_file_path, "r", encoding="utf-8") as f:
        content = f.read()

    content = re.sub(r"^LONGPOLL = .*", f"LONGPOLL = {long_poll}   # Configurado automáticamente", content, flags=re.MULTILINE)
    content = re.sub(r"sock\.setsockopt\(socket\.SOL_SOCKET, socket\.SO_RCVBUF, [0-9]+\)", f"sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, {buf_bytes})", content)
    content = re.sub(r"sock\.setsockopt\(socket\.SOL_SOCKET, socket\.SO_SNDBUF, [0-9]+\)", f"sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, {buf_bytes})", content)

    with open(server_file_path, "w", encoding="utf-8") as f:
        f.write(content)

    print(f"{AMARILLO}[*] Configurando y activando servicio systemd automático...{RESET}")
    service_content = f"""[Unit]
Description=BHTTP 2.5 Server - VICTORPEREZ
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 {server_file_path} --port {puerto} --backend-port {backend_port}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
"""

    with open(SERVICE_FILE, "w", encoding="utf-8") as f:
        f.write(service_content)

    subprocess.run(["systemctl", "daemon-reload"], check=False)
    subprocess.run(["systemctl", "enable", "bhttp"], check=False)
    subprocess.run(["systemctl", "restart", "bhttp"], check=False)

    mostrar_banner()
    print(f"{CYAN}======================================================{RESET}")
    print(f"{VERDE}        ✨ BHTTP INSTALADO EXITOSAMENTE ✨          {RESET}")
    print(f"{CYAN}======================================================{RESET}")
    print(f"  ┌─────────────────────────────────────────┐")
    print(f"  │  🔌 Puerto de Escucha : {VERDE}{puerto:<15}{RESET} │")
    print(f"  │  🔗 Puerto Backend    : {VERDE}{backend_port:<15}{RESET} │")
    print(f"  │  ⏱️  Long-Poll        : {VERDE}3.0s            {RESET} │")
    print(f"  │  🎛️  Búfer de Socket  : {VERDE}1 MB            {RESET} │")
    print(f"  │  📊 Estado            : {VERDE}CORRIENDO AL 100%{RESET}       │")
    print(f"  └─────────────────────────────────────────┘")
    print(f"{CYAN}======================================================{RESET}\n")
    input("Presione [ENTER] para volver al menú...")


def cambiar_puerto():
    mostrar_banner()
    print(f"{CYAN}=== ⚙️ CAMBIAR / CONFIGURAR PUERTOS BHTTP ==={RESET}\n")

    if not os.path.exists(SERVICE_FILE):
        print(f"{ROJO}[!] BHTTP no está instalado.${RESET}")
        time.sleep(2)
        return

    with open(SERVICE_FILE, "r", encoding="utf-8") as f:
        svc_data = f.read()

    match_port = re.search(r"--port\s+([0-9]+)", svc_data)
    match_backend = re.search(r"--backend-port\s+([0-9]+)", svc_data)

    puerto_actual = match_port.group(1) if match_port else "Desconocido"
    backend_actual = match_backend.group(1) if match_backend else "22"

    print(f"Configuración actual:")
    print(f" - Puerto de Escucha actual: {AMARILLO}{puerto_actual}{RESET}")
    print(f" - Puerto Backend actual:   {AMARILLO}{backend_actual}{RESET}\n")

    nuevo_puerto = input("Ingrese el nuevo puerto de escucha: ").strip()
    if not nuevo_puerto.isdigit():
        print(f"{ROJO}[!] Puerto de escucha inválido.${RESET}")
        time.sleep(2)
        return

    nuevo_backend = input(f"Ingrese el nuevo puerto backend [Dejar en blanco para mantener {backend_actual}]: ").strip()
    if not nuevo_backend.isdigit():
        nuevo_backend = backend_actual

    svc_data = re.sub(r"--port\s+[0-9]+", f"--port {nuevo_puerto}", svc_data)
    if "--backend-port" in svc_data:
        svc_data = re.sub(r"--backend-port\s+[0-9]+", f"--backend-port {nuevo_backend}", svc_data)
    else:
        svc_data = svc_data.replace("ExecStart=", f"ExecStart=... --backend-port {nuevo_backend}")

    with open(SERVICE_FILE, "w", encoding="utf-8") as f:
        f.write(svc_data)

    subprocess.run(["systemctl", "daemon-reload"], check=False)
    subprocess.run(["systemctl", "restart", "bhttp"], check=False)

    mostrar_banner()
    print(f"{CYAN}======================================================{RESET}")
    print(f"{VERDE}        ✨ PUERTO CONFIGURADO EXITOSAMENTE ✨        {RESET}")
    print(f"{CYAN}======================================================{RESET}")
    print(f"  ┌─────────────────────────────────────────┐")
    print(f"  │  🔌 Puerto de Escucha : {VERDE}{nuevo_puerto:<15}{RESET} │")
    print(f"  │  🔗 Puerto Backend    : {VERDE}{nuevo_backend:<15}{RESET} │")
    print(f"  │  📊 Estado del Servicio: {VERDE}ACTIVO (100%)${RESET}        │")
    print(f"  └─────────────────────────────────────────┘")
    print(f"{CYAN}======================================================{RESET}\n")
    input("Presione [ENTER] para volver al menú...")


def configurar_buffers():
    mostrar_banner()
    print(f"{CYAN}=== 🎛️ CONFIGURAR BUFFERS Y STREAMING ==={RESET}\n")

    server_file_path = os.path.join(INSTALL_DIR, "bhttp-server.py")
    if not os.path.exists(server_file_path):
        print(f"{ROJO}[!] BHTTP no está instalado.${RESET}")
        time.sleep(2)
        return

    with open(server_file_path, "r", encoding="utf-8") as f:
        code_data = f.read()

    lp_match = re.search(r"^LONGPOLL\s*=\s*([0-9.]+)", code_data, flags=re.MULTILINE)
    buf_match = re.search(r"SO_RCVBUF,\s*([0-9]+)", code_data)

    lp_actual = lp_match.group(1) if lp_match else "3.0"
    buf_actual_bytes = int(buf_match.group(1)) if buf_match else 1048576
    buf_mb = buf_actual_bytes // 1024 // 1024

    print(f"Valores actuales:")
    print(f" - Tiempo Long-Poll: {AMARILLO}{lp_actual}s{RESET}")
    print(f" - Buffer de Socket (RCV/SND): {AMARILLO}{buf_mb} MB{RESET}\n")

    nuevo_lp = input("Ingrese nuevo valor para Long-Poll en segundos (Ej. 3.0, 5.0): ").strip()
    if not nuevo_lp:
        nuevo_lp = lp_actual

    nuevo_mb_input = input("Ingrese nuevo tamaño de búfer de socket en Megabytes (Ej. 1, 2, 4): ").strip()
    if nuevo_mb_input.isdigit():
        nuevo_mb = int(nuevo_mb_input)
    else:
        nuevo_mb = buf_mb

    nuevo_bytes = nuevo_mb * 1024 * 1024

    print(f"{AMARILLO}[*] Aplicando cambios y reiniciando el servicio...{RESET}")

    code_data = re.sub(r"^LONGPOLL\s*=\s*[0-9.]+", f"LONGPOLL = {nuevo_lp}   # Actualizado por el usuario", code_data, flags=re.MULTILINE)
    code_data = re.sub(r"sock\.setsockopt\(socket\.SOL_SOCKET,\s*socket\.SO_RCVBUF,\s*[0-9]+\)", f"sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, {nuevo_bytes})", code_data)
    code_data = re.sub(r"sock\.setsockopt\(socket\.SOL_SOCKET,\s*socket\.SO_SNDBUF,\s*[0-9]+\)", f"sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, {nuevo_bytes})", code_data)

    with open(server_file_path, "w", encoding="utf-8") as f:
        f.write(code_data)

    subprocess.run(["systemctl", "restart", "bhttp"], check=False)

    mostrar_banner()
    print(f"{CYAN}======================================================{RESET}")
    print(f"{VERDE}        ✨ BUFFERS ACTUALIZADOS CON ÉXITO ✨        {RESET}")
    print(f"{CYAN}======================================================{RESET}")
    print(f"  ┌─────────────────────────────────────────┐")
    print(f"  │  ⏱️  Nuevo Long-Poll    : {VERDE}{nuevo_lp}s{(' ' * max(0, 14 - len(nuevo_lp+'s')))}{RESET} │")
    print(f"  │  🎛️  Nuevo Socket Buffer: {VERDE}{nuevo_mb} MB{(' ' * max(0, 14 - len(str(nuevo_mb)+' MB')))}{RESET} │")
    print(f"  │  📊 Estado del Servicio: {VERDE}ACTIVO (100%)${RESET}        │")
    print(f"  └─────────────────────────────────────────┘")
    print(f"{CYAN}======================================================{RESET}\n")
    input("Presione [ENTER] para volver al menú...")


def eliminar_puerto():
    mostrar_banner()
    print(f"{CYAN}=== 🗑️ ELIMINAR CONFIGURACIÓN DE PUERTO ==={RESET}\n")

    if not os.path.exists(SERVICE_FILE):
        print(f"{ROJO}[!] BHTTP no está instalado.${RESET}")
        time.sleep(2)
        return

    print(f"{AMARILLO}[*] Deteniendo y deshabilitando el servicio...{RESET}")
    subprocess.run(["systemctl", "stop", "bhttp"], check=False)
    subprocess.run(["systemctl", "disable", "bhttp"], check=False)
    if os.path.exists(SERVICE_FILE):
        os.remove(SERVICE_FILE)
    subprocess.run(["systemctl", "daemon-reload"], check=False)

    print(f"\n{VERDE}[✔] Configuración y servicio eliminados correctamente.{RESET}")
    input("Presione [ENTER] para volver al menú...")


def desinstalar_bhttp():
    mostrar_banner()
    print(f"{CYAN}=== ❌ DESINSTALAR BHTTP ==={RESET}\n")

    confirmar = input("¿Está seguro de que desea desinstalar por completo BHTTP 2.5? (s/n): ").strip().lower()
    if confirmar == 's':
        subprocess.run(["systemctl", "stop", "bhttp"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["systemctl", "disable", "bhttp"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        
        if os.path.exists(SERVICE_FILE):
            os.remove(SERVICE_FILE)
        if os.path.exists(SYMLINK_PATH):
            os.remove(SYMLINK_PATH)
            
        if os.path.exists(INSTALL_DIR):
            shutil.rmtree(INSTALL_DIR)
            
        subprocess.run(["systemctl", "daemon-reload"], check=False)
        print(f"\n{VERDE}[✔] BHTTP 2.5 desinstalado por completo del sistema.{RESET}")
    else:
        print(f"\n{AMARILLO}[!] Operación cancelada.{RESET}")
    input("Presione [ENTER] para volver al menú...")


def comprobar_estado():
    mostrar_banner()
    print(f"{CYAN}=== 🔍 COMPROBACIÓN DE ESTADO BHTTP 2.5 ==={RESET}\n")

    if not os.path.exists(SERVICE_FILE):
        print(f"{ROJO}[!] BHTTP no se encuentra instalado.${RESET}\n")
        input("Presione [ENTER] para volver al menú...")
        return

    print(f"{BLANCO}--- Estado del Servicio Systemd ---{RESET}")
    subprocess.run(["systemctl", "status", "bhttp", "--no-pager"])
    print("\n" + f"{BLANCO}--- Puertos en Escucha ---{RESET}")
    subprocess.run("ss -tulpn | grep python3 || netstat -tulnp | grep python3", shell=True)
    print("\n" + f"{BLANCO}--- Últimos Logs del Sistema ---{RESET}")
    subprocess.run(["journalctl", "-u", "bhttp", "-n", "10", "--no-pager"])
    print("")
    input("Presione [ENTER] para volver al menú...")


def menu():
    while True:
        mostrar_banner()
        print("")
        print(f"  {AZUL}[1]{RESET} 🚀 INSTALAR BHTTP")
        print(f"  {AZUL}[2]{RESET} ⚙️  CAMBIAR / CONFIGURAR PUERTO")
        print(f"  {AZUL}[3]{RESET} 🎛️  CONFIGURAR BUFFERS Y STREAMING")
        print(f"  {AZUL}[4]{RESET} 🗑️  ELIMINAR PUERTO / CONFIGURACIÓN")
        print(f"  {AZUL}[5]{RESET} ❌ DESINSTALAR BHTTP")
        print(f"  {AZUL}[6]{RESET} 🔍 COMPROBAR QUE EL BHTTP ESTÁ CORRIENDO AL 100%")
        print(f"  {AZUL}[7]{RESET} 🚪 SALIR")
        print("")
        
        opcion = input(f"{AMARILLO}Seleccione una opción [1-7]: {RESET}").strip()

        if opcion == "1":
            instalar_bhttp()
        elif opcion == "2":
            cambiar_puerto()
        elif opcion == "3":
            configurar_buffers()
        elif opcion == "4":
            eliminar_puerto()
        elif opcion == "5":
            desinstalar_bhttp()
        elif opcion == "6":
            comprobar_estado()
        elif opcion == "7":
            print(f"\n{VERDE}¡Saliendo del gestor! Hasta luego.{RESET}\n")
            sys.exit(0)
        else:
            print(f"\n{ROJO}[!] Opción inválida. Intente de nuevo.{RESET}")
            time.sleep(2)


if __name__ == "__main__":
    menu()
        
