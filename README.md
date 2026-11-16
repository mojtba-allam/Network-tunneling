# Ubuntu OpenConnect split tunnel

VPN stays the default route. Iranian prefixes and `10.14.0.0/16` go via Wi-Fi.
`.ir` DNS uses the ISP resolvers; everything else stays on VPN DNS.

## Install and run (one command)

From GitHub, on the machine that already has OpenConnect/`nl` up:

```bash
curl -fsSL https://raw.githubusercontent.com/mojtba-allam/Network-tunneling/main/install.sh | bash
```

That downloads the scripts into `~/network-split-tunnel`, takes a routing backup, and applies the split tunnel (`sudo` will ask for your password).

## After install

```bash
~/network-split-tunnel/network-split-tunnel.sh status
~/network-split-tunnel/network-split-tunnel.sh test
sudo ~/network-split-tunnel/rollback.sh
```

## Manual clone

```bash
git clone https://github.com/mojtba-allam/Network-tunneling.git
sudo SPLIT_TUNNEL_CONFIRM=yes ./Network-tunneling/network-split-tunnel/network-split-tunnel.sh apply
```
