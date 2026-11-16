# Safe split tunnel (OpenConnect `nl` + Wi-Fi `Pishgaman`)

VPN keeps the default route. Iranian prefixes and `10.14.0.0/16` go via Wi-Fi.
`.ir` DNS uses Pishgaman (`5.202.100.100`); other names stay on VPN DNS (`8.8.8.8`).

## Install and run (one command)

```bash
curl -fsSL https://raw.githubusercontent.com/mojtba-allam/Network-tunneling/main/install.sh | bash
```

## Apply (already cloned)

```bash
sudo SPLIT_TUNNEL_CONFIRM=yes ./network-split-tunnel.sh apply
```

## Rollback

```bash
sudo ./rollback.sh
```

## Test

```bash
./network-split-tunnel.sh test
```
