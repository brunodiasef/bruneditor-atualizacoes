#!/usr/bin/env bash
# =============================================================================================================
# BRUNEDITOR na nuvem: instala tudo num servidor Ubuntu (feito para o Oracle Cloud "Always Free", ARM ou AMD).
#
# Uso, no terminal do servidor (um comando só):
#   curl -fsSL https://raw.githubusercontent.com/brunodiasef/bruneditor-atualizacoes/main/instalar_nuvem.sh -o instalar.sh && sudo bash instalar.sh
#
# O que ele faz: instala FFmpeg, fontes, Caddy (HTTPS com cadeado) e Python 3.13; baixa a última versão publicada do
# BRUNEDITOR e os modelos de IA; pede a senha de entrada e (se quiser) a chave do Groq; libera as portas 80/443 no
# firewall do Ubuntu; e deixa o programa ligando sozinho quando o servidor reiniciar.
# Pode rodar de novo a qualquer momento: atualiza o que faltar e mantém projetos, senha e chave.
#
# Variáveis opcionais (para instalar sem perguntas):
#   BRUNEDITOR_SENHA=...      senha de entrada (mínimo 10 caracteres)
#   GROQ_CHAVE=...            chave do Groq (gsk_...); "nenhuma" = transcrever só no servidor
#   DOMINIO=...               endereço próprio (sem ele: <ip>.sslip.io, que já aponta para este servidor)
#   PACOTE_LOCAL=/caminho.zip instala um pacote local em vez do último Release (para testes)
# =============================================================================================================
set -euo pipefail

PASTA=/opt/bruneditor
APP=$PASTA/app
USUARIO=bruneditor
REPO=brunodiasef/bruneditor-atualizacoes
PYTHON_VERSAO=3.13

passo() { echo; echo "==> $*"; }
aviso() { echo "    $*"; }

if [ "$(id -u)" != 0 ]; then exec sudo -E bash "$0" "$@"; fi
export DEBIAN_FRONTEND=noninteractive

passo "1/9 Programas do sistema (FFmpeg, fontes, ferramentas)"
apt-get update -y -q
echo "ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true" | debconf-set-selections
apt-get install -y -q sudo curl ca-certificates unzip xz-utils fontconfig fonts-liberation fonts-dejavu-core \
  fonts-noto-core fonts-roboto fonts-open-sans gnupg debian-keyring debian-archive-keyring apt-transport-https >/dev/null
# fontes da Microsoft (Arial Black, Impact, Verdana, Georgia...): baixadas da origem; se falhar, segue sem elas
apt-get install -y -q ttf-mscorefonts-installer >/dev/null 2>&1 || aviso "(fontes da Microsoft não instaladas; segue sem elas)"

# FFmpeg 9 (o do Ubuntu é antigo demais): mesma origem do instalador do Windows (BtbN/FFmpeg-Builds)
if ! /usr/local/bin/ffmpeg -version 2>/dev/null | head -1 | grep -qE 'version n?(9|[1-9][0-9])\.'; then
  case "$(uname -m)" in aarch64|arm64) ARQ=linuxarm64 ;; *) ARQ=linux64 ;; esac
  URL=$(curl -fsSL https://api.github.com/repos/BtbN/FFmpeg-Builds/releases/latest         | grep -oE "https://[^\"]*ffmpeg-n9\.[0-9]+-latest-$ARQ-gpl-9.[0-9]+.tar.xz" | head -1 || true)
  URL=${URL:-https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-$ARQ-gpl.tar.xz}
  aviso "baixando o FFmpeg: $(basename "$URL")"
  T=$(mktemp -d) && curl -fsSL "$URL" | tar -xJ -C "$T" --strip-components=1
  install -m 755 "$T/bin/ffmpeg" "$T/bin/ffprobe" /usr/local/bin/ && rm -rf "$T"
fi
aviso "$(/usr/local/bin/ffmpeg -version | head -1 | cut -c1-60)"

passo "2/9 Caddy (HTTPS com cadeado)"
if ! command -v caddy >/dev/null; then
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -y -q && apt-get install -y -q caddy >/dev/null
fi
aviso "$(caddy version | head -1)"

passo "3/9 Usuário do programa e Python $PYTHON_VERSAO"
id "$USUARIO" >/dev/null 2>&1 || useradd --system --create-home --home-dir "$PASTA" --shell /usr/sbin/nologin "$USUARIO"
mkdir -p "$APP" "$PASTA/cache"
if ! command -v uv >/dev/null; then
  curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1 sh >/dev/null
fi
export UV_PYTHON_INSTALL_DIR=$PASTA/python UV_CACHE_DIR=$PASTA/cache/uv
uv python install "$PYTHON_VERSAO" >/dev/null
[ -x "$PASTA/venv/bin/python" ] || uv venv --python "$PYTHON_VERSAO" "$PASTA/venv" >/dev/null
PY=$PASTA/venv/bin/python
aviso "$($PY --version)"

passo "4/9 Bibliotecas do programa"
uv pip install --python "$PY" -q Flask waitress faster-whisper ctranslate2 numpy pillow onnxruntime \
  huggingface_hub sentencepiece fonttools

passo "5/9 BRUNEDITOR (última versão publicada)"
TMP=$(mktemp -d)
if [ -n "${PACOTE_LOCAL:-}" ]; then
  cp "$PACOTE_LOCAL" "$TMP/pacote.zip"; aviso "pacote local: $PACOTE_LOCAL"
else
  "$PY" - "$REPO" "$TMP" <<'PYEOF'
import hashlib, json, sys, urllib.request
repo, tmp = sys.argv[1], sys.argv[2]
def get(u, raw=False):
    r = urllib.request.urlopen(urllib.request.Request(u, headers={"User-Agent": "BRUNEDITOR"}), timeout=60)
    return r.read() if raw else json.load(r)
num = lambda v: tuple(int(x) for x in v.lstrip("vV").split(".")[:3]) if v.lstrip("vV").replace(".", "").isdigit() else (0,)
rels = [r for r in get(f"https://api.github.com/repos/{repo}/releases?per_page=30") if not r.get("draft")
        and {"bruneditor-atualizacao.zip", "bruneditor-atualizacao.sha256"} <= {a["name"] for a in r.get("assets", [])}]
rel = max(rels, key=lambda r: num(r["tag_name"]))
arq = {a["name"]: a["browser_download_url"] for a in rel["assets"]}
zipb = get(arq["bruneditor-atualizacao.zip"], True)
soma = get(arq["bruneditor-atualizacao.sha256"], True).decode().split()[0].lower()
if hashlib.sha256(zipb).hexdigest() != soma:
    sys.exit("O pacote baixado não confere com a soma SHA256 publicada.")
open(f"{tmp}/pacote.zip", "wb").write(zipb)
print("    versão", rel["tag_name"])
PYEOF
fi
"$PY" - "$TMP/pacote.zip" "$APP" <<'PYEOF'
import json, os, sys, zipfile
zp, app = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(zp) as z:
    m = json.loads(z.read("manifesto.json"))
    if "servidor.py" not in m["arquivos"]:
        sys.exit(f"A versão {m['versao']} ainda não tem o modo nuvem (servidor.py). Publique uma versão nova e rode de novo.")
    py = f"{sys.version_info[0]}.{sys.version_info[1]}"
    if m.get("python") and m["python"] != py:
        sys.exit(f"O pacote precisa do Python {m['python']} (o servidor tem o {py}).")
    for n in m["arquivos"]:
        if ".." in n or n.startswith("/"):
            continue
        destino = os.path.join(app, n)
        os.makedirs(os.path.dirname(destino), exist_ok=True)
        with z.open(n) as o, open(destino + ".novo", "wb") as f:
            f.write(o.read())
        os.replace(destino + ".novo", destino)
    for n in m.get("remover", []):
        v = os.path.join(app, n)
        if os.path.isfile(v) and n not in m["arquivos"]:
            os.remove(v)
    open(os.path.join(app, "versao.txt"), "w").write(m["versao"] + "\n")
    print("    instalada a versão", m["versao"])
PYEOF
rm -rf "$TMP"

passo "6/9 Modelos de IA (recorte de pessoa, rosto, separar voz) e fontes extras"
mkdir -p "$APP/modelos" "$APP/fontes"
baixar() { [ -s "$2" ] || { aviso "baixando $(basename "$2")"; curl -fsSL "$1" -o "$2.parcial" && mv "$2.parcial" "$2"; }; }
baixar "https://github.com/onnx/models/raw/main/validated/vision/body_analysis/ultraface/models/version-RFB-320.onnx" "$APP/modelos/rosto-ultraface-320.onnx"
baixar "https://github.com/PeterL1n/RobustVideoMatting/releases/download/v1.0.0/rvm_mobilenetv3_fp32.onnx" "$APP/modelos/recorte-rvm-mobilenetv3.onnx"
baixar "https://github.com/TRvlvr/model_repo/releases/download/all_public_uvr_models/Kim_Vocal_2.onnx" "$APP/modelos/separar-voz-kim2.onnx"
# Montserrat e Poppins (licença livre OFL), muito usadas em legendas de Reels
for peso in Regular Medium SemiBold Bold ExtraBold Black; do
  baixar "https://raw.githubusercontent.com/JulietaUla/Montserrat/master/fonts/ttf/Montserrat-$peso.ttf" "$APP/fontes/Montserrat-$peso.ttf" || true
  baixar "https://raw.githubusercontent.com/google/fonts/main/ofl/poppins/Poppins-$peso.ttf" "$APP/fontes/Poppins-$peso.ttf" || true
done
mkdir -p /usr/local/share/fonts/bruneditor && cp -n "$APP"/fontes/*.ttf /usr/local/share/fonts/bruneditor/ 2>/dev/null || true
fc-cache -f >/dev/null 2>&1 || true
chown -R "$USUARIO:$USUARIO" "$PASTA"

passo "7/9 Senha de entrada e chave do Groq"
como() { sudo -u "$USUARIO" -E env HOME="$PASTA" HF_HOME="$PASTA/cache/hf" "$@"; }
cd "$APP"
if "$PY" -c "import json,sys; sys.exit(0 if json.load(open('nuvem.json')).get('senha') else 1)" 2>/dev/null && [ -z "${BRUNEDITOR_SENHA:-}" ]; then
  aviso "senha já definida (para trocar: sudo -u $USUARIO $PY $APP/servidor.py --senha)"
else
  como "$PY" servidor.py --senha
fi
if [ -n "${GROQ_CHAVE:-}" ]; then
  [ "$GROQ_CHAVE" = "nenhuma" ] && GROQ_CHAVE=""
  como "$PY" servidor.py --groq "$GROQ_CHAVE"
elif ! "$PY" -c "import json,sys; sys.exit(0 if json.load(open('nuvem.json')).get('groq') else 1)" 2>/dev/null; then
  if [ -t 0 ]; then
    read -r -p "    Cole a chave do Groq (gsk_...) ou aperte Enter para transcrever só no servidor: " GROQ_CHAVE || true
    como "$PY" servidor.py --groq "${GROQ_CHAVE:-}"
  fi
else
  aviso "chave do Groq já gravada"
fi

passo "8/9 Serviço (liga sozinho) e HTTPS"
IP=$(curl -fsS https://api.ipify.org || curl -fsS https://ifconfig.me || echo "")
HOST=${DOMINIO:-${IP//./-}.sslip.io}
cat > /etc/caddy/Caddyfile <<EOF
$HOST {
	encode zstd gzip
	request_body {
		max_size 8GB
	}
	reverse_proxy 127.0.0.1:5005 {
		transport http {
			read_timeout 30m
			write_timeout 30m
		}
	}
}
EOF
cat > /etc/systemd/system/bruneditor.service <<EOF
[Unit]
Description=BRUNEDITOR (nuvem)
After=network-online.target
Wants=network-online.target

[Service]
User=$USUARIO
WorkingDirectory=$APP
ExecStart=$PY $APP/servidor.py
Restart=always
RestartSec=3
Environment=PYTHONUNBUFFERED=1
Environment=HOME=$PASTA
Environment=HF_HOME=$PASTA/cache/hf

[Install]
WantedBy=multi-user.target
EOF
if [ -d /run/systemd/system ]; then
  systemctl daemon-reload
  systemctl enable --now bruneditor >/dev/null 2>&1
  systemctl restart bruneditor
  systemctl enable caddy >/dev/null 2>&1 && systemctl restart caddy
else
  aviso "(sem systemd aqui: o serviço foi criado mas não ligado)"
fi

passo "9/9 Firewall do Ubuntu (portas 80 e 443)"
if command -v iptables >/dev/null; then
  for porta in 80 443; do
    iptables -C INPUT -p tcp --dport $porta -m conntrack --ctstate NEW -j ACCEPT 2>/dev/null || \
      iptables -I INPUT 1 -p tcp --dport $porta -m conntrack --ctstate NEW -j ACCEPT 2>/dev/null || true
  done
  command -v netfilter-persistent >/dev/null && netfilter-persistent save >/dev/null 2>&1 || true
fi
command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q active && { ufw allow 80/tcp; ufw allow 443/tcp; } >/dev/null || true

echo
echo "============================================================================================"
echo " BRUNEDITOR instalado. Abra no navegador (computador ou celular):"
echo
echo "     https://$HOST"
echo
echo " Se não abrir: confira se as portas 80 e 443 estão liberadas na Oracle (Lista de Segurança da VCN)."
echo " Ver o que está acontecendo:  sudo journalctl -u bruneditor -f"
echo " As atualizações publicadas entram sozinhas (de hora em hora, quando ninguém estiver usando)."
echo "============================================================================================"
