Abaixo vai um tutorial completo (e bem prático) para **instalar, autenticar e configurar o Tailscale**, incluindo **Exit Node** e dicas para rodar **automaticamente**. No final tem uma seção específica para **Docker**, que é onde normalmente surgem os problemas.

---

## 1) Instalar o Tailscale (Linux)

### Opção A (recomendado: script oficial)
```bash
curl -fsSL https://tailscale.com/install.sh | sh
```

Verifique:
```bash
tailscale version
```

### Opção B (Debian/Ubuntu)
Depois de adicionar o repo (o script acima já faz isso), instale:
```bash
sudo apt-get update
sudo apt-get install -y tailscale
```

---

## 2) Subir o serviço automaticamente (systemd)

Em máquinas Linux “normais” (VM/VPS/bare metal) com systemd:
```bash
sudo systemctl enable --now tailscaled
```

Checar:
```bash
sudo systemctl status tailscaled --no-pager
```

---

## 3) Fazer login (autenticação)

### Login interativo (mais comum)
```bash
sudo tailscale up
```
Ele vai mostrar um link para você autenticar.

### Login automático (servidor/produção) com Auth Key
No painel do Tailscale (Admin Console → **Settings → Keys**), crie uma **auth key** e use:
```bash
sudo tailscale up --authkey tskey-XXXX --hostname meu-servidor --accept-dns=false
```

---

## 4) Verificar se está conectado
```bash
tailscale status
tailscale ip -4
tailscale ping <nome-ou-ip-100.x-do-outro-device>
```

---

## 5) Habilitar um dispositivo como Exit Node (máquina que “fornece” internet)

### Em Linux/macOS (como Exit Node)
Na máquina que será o Exit Node:
```bash
sudo tailscale up --advertise-exit-node
```

Depois, no Admin Console, pode ser necessário **aprovar** o Exit Node.

### Em Windows (como Exit Node)
No app do Tailscale:
- Settings/Preferences
- Ativar **“Use as exit node” / “Advertise as exit node”**

---

## 6) Usar um Exit Node (máquina que “consome” a saída)

Listar exit nodes disponíveis:
```bash
tailscale exit-node list
```

Aplicar um exit node:
```bash
sudo tailscale set --exit-node=<IP-ou-hostname> --exit-node-allow-lan-access=true
```

Verificar se o tráfego mudou:
```bash
curl https://ifconfig.me
```

Para remover o exit node:
```bash
sudo tailscale set --exit-node=
```

---

## 7) (Opcional) Habilitar acesso a LAN do exit node
Já incluí acima com:
```bash
--exit-node-allow-lan-access=true
```
Isso permite acessar IPs da rede local do exit node (ex.: 192.168.0.x).

---

# 8) Tutorial específico: Tailscale em Docker (o mais importante)

**Atenção:** criar `/dev/net/tun` no Dockerfile **não resolve**. Você precisa passar no **docker run**:
- `--device=/dev/net/tun`
- `--cap-add=NET_ADMIN`

### Exemplo docker run
```bash
docker run -d --name app \
  --cap-add=NET_ADMIN \
  --device=/dev/net/tun \
  -v appdata:/data \
  <sua-imagem>
```

### Exemplo docker-compose.yml
```yaml
services:
  app:
    image: <sua-imagem>
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
```

### Rodar automaticamente dentro do container
Se o container **não** tem systemd, você precisa iniciar o `tailscaled` no entrypoint e manter ele vivo.

Exemplo (bem simples) no entrypoint:
```bash
tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock &
sleep 1
tailscale --socket=/var/run/tailscale/tailscaled.sock up --authkey tskey-XXXX --accept-dns=false
exec <seu-processo-principal>
```

**Sem `NET_ADMIN` + `/dev/net/tun`**, o Tailscale pode conectar em “userspace”, mas:
- não consegue mexer em rotas/iptables
- e o Exit Node não funciona como VPN do sistema

---

## Checklist rápido (para não dar dor de cabeça)

1) `tailscale version` funciona  
2) `tailscaled` está rodando (systemd ou em background)  
3) `tailscale status` mostra “Running” e IP 100.x  
4) Se usar Exit Node:
   - `tailscale exit-node list` mostra exit nodes
   - `tailscale set --exit-node=...` aplica
   - `curl ifconfig.me` muda o IP

---