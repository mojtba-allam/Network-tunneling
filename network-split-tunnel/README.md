# Safe split tunnel (OpenConnect `nl` + Wi-Fi `Pishgaman`)

VPN keeps the default route. Iranian prefixes and `10.14.0.0/16` go via Wi-Fi.
`.ir` DNS uses Pishgaman (`5.202.100.100`); other names stay on VPN DNS (`8.8.8.8`).
That avoids ISP hijack of YouTube (`10.10.34.36`).

## Apply (needs sudo)

```bash
sudo SPLIT_TUNNEL_CONFIRM=yes /home/panda/network-split-tunnel/network-split-tunnel.sh apply
```

## Rollback

```bash
sudo /home/panda/network-split-tunnel/rollback.sh
```

## Test

```bash
/home/panda/network-split-tunnel/network-split-tunnel.sh test
```

Evidence: `golestan.ikiu.ac.ir` → `10.14.0.24` via Wi-Fi returned HTTP 200.
`185.114.188.24` via VPN times out.
