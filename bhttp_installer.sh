#!/bin/bash
# BHTTP PRO - INSTALADOR COMPACTO (Victor Pérez)
# Versión corregida para GitHub

C="\033[1;36m";G="\033[1;32m";Y="\033[1;33m";R="\033[1;31m";M="\033[1;35m";RE="\033[0m"
I="/usr/local/lib/bhttp";S="/etc/systemd/system/bhttp.service";P="$I/bhttp-server.py";MENU="/usr/local/bin/bhttp-menu"
[[ "$EUID" -ne 0 ]] && echo -e "${R}[!] Ejecuta como root${RE}" && exit 1

# Verificar Python3
command -v python3 >/dev/null 2>&1 || { apt update; apt install -y python3; }

banner(){ clear;echo -e "${M}============================================================${RE}";echo -e "${C}        BHTTP PRO - INSTALADOR COMPACTO${RE}";echo -e "${Y}             Victor Pérez${RE}";echo -e "${M}============================================================${RE}";}

crear_py(){ mkdir -p "$I";cat > "$P" <<'PY'
#!/usr/bin/env python3
import argparse,asyncio,hashlib,sys,socket
MAGIC=b"BHP1";LONGPOLL=3.0
def log(m):sys.stderr.write(f"[bhttp‑pro] {m}\n")
def keystream(sess,mode,seq,d,n):
    b=hashlib.sha256(sess+bytes([mode])+seq.to_bytes(8,"big")+bytes([d]))
    o=bytearray();c=0
    while len(o)<n:h=b.copy();h.update(c.to_bytes(4,"big"));o+=h.digest();c+=1
    return bytes(o[:n])
def mask(d,s,m,seq,di):return bytes(a^b for a,b in zip(d,keystream(s,m,seq,di,len(d))))
def probe_reply(mode,size):n=size if(mode==2 and size>=10)else 10;o=bytearray(MAGIC+bytes([1,mode])+size.to_bytes(4,"big"));for i in range(10,n):o.append((i*31)&255);return bytes(o)
def opt_sock(s):try:s.setsockopt(socket.IPPROTO_TCP,socket.TCP_NODELAY,1);s.setsockopt(socket.SOL_SOCKET,socket.SO_RCVBUF,1048576);s.setsockopt(socket.SOL_SOCKET,socket.SNDBUF,1048576);except:pass
class Session:
    def __init__(self,sess,backend):self.sess=sess;self.backend=backend;self.cond=asyncio.Condition();self.up_next=0;self.up_pending={};self.down_raw=bytearray();self.down_chunks={};self.down_assign=0;self.eof=False;self.closed=False;self.br=None;self.bw=None
    async def connect(self):h,p=self.backend;self.br,self.bw=await asyncio.open_connection(h,p);s=self.bw.get_extra_info("socket");if s:opt_sock(s);asyncio.create_task(self._reader())
    async def _reader(self):try:while True:d=await self.br.read(131072);if not d:break;async with self.cond:self.down_raw+=d;self.cond.notify_all();except:pass;finally:async with self.cond:self.eof=True;self.cond.notify_all()
    async def upload(self,seq,data):async with self.cond:if data:self.up_pending[seq]=data;while self.up_next in self.up_pending:ch=self.up_pending.pop(self.up_next);try:self.bw.write(ch);await self.bw.drain();except:self.closed=True;self.up_next+=1
    async def download(self,seq,ml,dl):if ml<=0:ml=65536;l=asyncio.get_running_loop();async with self.cond:while True:if seq<self.down_assign:return self.down_chunks.get(seq,b"");if seq==self.down_assign:if self.down_raw:t=bytes(self.down_raw[:ml]);del self.down_raw[:ml];self.down_chunks[self.down_assign]=t;self.down_assign+=1;self.cond.notify_all();return t;if self.eof:self.down_assign+=1;self.cond.notify_all();return b"";if not self.eof and l.time()<dl:try:await asyncio.wait_for(self.cond.wait(),timeout=max(0.005,dl-l.time()));except asyncio.TimeoutError:pass;continue;while self.down_assign<=seq:self.down_assign+=1;self.cond.notify_all();return b""
    async def ack(self,seq):async with self.cond:for k in [k for k in self.down_chunks if k<=seq]:del self.down_chunks[k]
    async def close(self):async with self.cond:self.closed=True;self.cond.notify_all();try:self.bw.close();except:pass
class Server:
    def __init__(self,h,p,b):self.host=h;self.port=p;self.backend=b;self.sessions={};self.slock=asyncio.Lock()
    async def get_session(self,sess):async with self.slock:s=self.sessions.get(sess);if s is None or s.closed:s=Session(sess,self.backend);await s.connect();self.sessions[sess]=s;return s
    async def handle(self,r,w):s=w.get_extra_info("socket");if s:opt_sock(s);try:while True:hdr=await r.readexactly(29);m=hdr[0];sess=hdr[1:17];seq=int.from_bytes(hdr[17:25],"big");ln=int.from_bytes(hdr[25:29],"big");pay=b"";if ln and m in (0,1,2,3):raw=await r.readexactly(ln);pay=mask(raw,sess,m,seq,0);if pay[:4]==MAGIC:size=int.from_bytes(pay[6:10],"big")if len(pay)>=10 else 0;pm=pay[5]if len(pay)>=6 else m;bd=mask(probe_reply(pm,size),sess,m,seq,1);w.write(bytes([0])+len(bd).to_bytes(4,"big")+bd);await w.drain();continue;s=await self.get_session(sess);if m==1:await s.upload(seq,pay);w.write(bytes([0])+(0).to_bytes(4,"big"));await w.drain();elif m==2:ch=await s.download(seq,ln if ln>0 else 65536,asyncio.get_running_loop().time()+LONGPOLL);self._send(w,sess,m,seq,ch);await w.drain();elif m==3:if len(pay)>=6:cs=int.from_bytes(pay[0:4],"big");cnt=pay[5];else:cs,cnt=65536,4;if cs<=0:cs=65536;if cnt<=0:cnt=4;dl=asyncio.get_running_loop().time()+LONGPOLL;for i in range(cnt):ch=await s.download(seq+i,cs,dl);self._send(w,sess,m,seq+i,ch);await w.drain();elif m==4:await s.ack(seq);w.write(bytes([0])+(0).to_bytes(4,"big"));await w.drain();else:return;except (asyncio.IncompleteReadError,ConnectionError,OSError):pass;except Exception as e:log(e);finally:try:w.close();except:pass
    def _send(self,w,sess,m,seq,d):rl=len(d);mk=mask(d,sess,m,seq,1)if d else b"";bd=rl.to_bytes(4,"big")+mk;w.write(bytes([2])+len(bd).to_bytes(4,"big")+bd)
    async def serve(self):srv=await asyncio.start_server(self.handle,self.host,self.port,backlog=8192);async with srv:await srv.serve_forever()
def main():ap=argparse.ArgumentParser();ap.add_argument("--host",default="0.0.0.0");ap.add_argument("--port",type=int,required=True);ap.add_argument("--backend-host",default="127.0.0.1");ap.add_argument("--backend-port",type=int,default=22);a=ap.parse_args();asyncio.run(Server(a.host,a.port,(a.backend_host,a.backend_port)).serve())
if __name__=="__main__":main()
PY
chmod +x "$P"
}

get_cfg(){ PORT=8080;BH="127.0.0.1";BP=22;[[ -f "$S" ]] && { EX=$(grep '^ExecStart=' "$S");[[ "$EX" =~ --port[[:space:]]+([0-9]+) ]] && PORT=${BASH_REMATCH[1]};[[ "$EX" =~ --backend-host[[:space:]]+([0-9a-zA-Z.]+) ]] && BH=${BASH_REMATCH[1]};[[ "$EX" =~ --backend-port[[:space:]]+([0-9]+) ]] && BP=${BASH_REMATCH[1]};};}

install(){ echo -e "${Y}[+] Instalando BHTTP PRO${RE}";crear_py;read -p "Puerto escucha [8080]: " p;p=${p:-8080};read -p "Backend Host [127.0.0.1]: " bh;bh=${bh:-127.0.0.1};read -p "Backend Puerto [22]: " bp;bp=${bp:-22};cat > "$S" <<EOF
[Unit]
Description=BHTTP PRO Victor Pérez
After=network.target
[Service]
Type=simple
User=root
WorkingDirectory=$I
ExecStart=/usr/bin/python3 $P --port $p --backend-host $bh --backend-port $bp
Restart=always
RestartSec=3
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload;systemctl enable --now bhttp 2>/dev/null;echo -e "${G}[✔] Instalado puerto $p${RE}";read -p "ENTER para continuar…"
}

uninstall(){ echo -e "${R}[!] Desinstalando${RE}";systemctl stop bhttp 2>/dev/null;systemctl disable bhttp 2>/dev/null;rm -f "$S";rm -rf "$I";systemctl daemon-reload;echo -e "${G}[✔] Desinstalado${RE}";read -p "ENTER para continuar…"
}

chg_port(){ [[ ! -f "$S" ]] && { echo -e "${R}[!] No instalado${RE}";read -p "ENTER…";return;};get_cfg;echo -e "${Y}Puerto actual: $PORT${RE}";read -p "Nuevo puerto: " np;[[ ! "$np" =~ ^[0-9]+$ ]] && { echo -e "${R}[!] Puerto inválido${RE}";read -p "ENTER…";return;};sed -i "s/--port [0-9]*/--port $np/g" "$S";systemctl daemon-reload;systemctl restart bhttp 2>/dev/null;echo -e "${G}[✔] Puerto cambiado $np${RE}";read -p "ENTER…"
}

chg_lp(){ [[ ! -f "$P" ]] && { echo -e "${R}[!] No instalado${RE}";read -p "ENTER…";return;};lp=$(grep '^LONGPOLL = ' "$P" | cut -d'=' -f2 | tr -d ' ');lp=${lp:-3.0};echo -e "${Y}LongPoll actual: ${lp}s${RE}";read -p "Nuevo valor (ej 5.0): " nlp;[[ ! "$nlp" =~ ^[0-9]+([.,][0-9]+)?$ ]] && { echo -e "${R}[!] Valor inválido${RE}";read -p "ENTER…";return;};nlp=$(echo "$nlp" | tr ',' '.');sed -i "s/^LONGPOLL = .*/LONGPOLL = $nlp/" "$P";systemctl restart bhttp 2>/dev/null;echo -e "${G}[✔] LongPoll $nlp s${RE}";read -p "ENTER…"
}

# Copiarse a bhttp‑menu para comando global
[[ ! -f "$MENU" ]] && { cp "$0" "$MENU";chmod +x "$MENU";}

while true;do
banner;get_cfg
if systemctl is-active --quiet bhttp 2>/dev/null;then echo -e "Estado: ${G}● ACTIVO${RE} | Puerto $PORT | $BH:$BP";else echo -e "Estado: ${R}● INACTIVO${RE}";fi
echo -e "${C}1) Instalar  2) Desinstalar  3) Cambiar Puerto  4) Editar LongPoll  7) Salir${RE}"
read -p "Selecciona opción: " op
case $op in
1) install ;;
2) uninstall ;;
3) chg_port ;;
4) chg_lp ;;
7) echo -e "${G}Saliendo…${RE}";exit 0 ;;
*) echo -e "${R}[!] Opción inválida${RE}";sleep 1 ;;
esac
done
