# Mihomo deployment

This directory contains Clash/Mihomo-compatible rule files converted from the
Shadowrocket rule sets in `../shadowrocket/`.

## Files

- `rules/ai-proxy.yaml`: AI and developer services routed through `PROXY`.
- `rules/social-media.yaml`: foreign social media routed through `PROXY`.
- `rules/remote-cn-direct.yaml`: mainland remote-access services routed through `DIRECT`.
- `rules/china.yaml`: mainland China domains, user agents, ASNs, and CIDRs routed through `DIRECT`.
- `deploy-mihomo.sh`: one-command Linux installer and systemd deployer.

## Deploy

Create a local file on the target server with one proxy share URL per line. Do
not commit that file.

```bash
sudo bash mihomo/deploy-mihomo.sh --proxy-urls /root/mihomo-proxy-urls.txt
```

If `/usr/local/bin/mihomo` is already installed, skip the release download:

```bash
sudo MIHOMO_SKIP_BINARY_INSTALL=1 \
  bash mihomo/deploy-mihomo.sh --proxy-urls /root/mihomo-proxy-urls.txt
```

By default, mihomo listens on `127.0.0.1:7890`. To expose it to other machines,
pass an explicit bind address:

```bash
sudo bash mihomo/deploy-mihomo.sh \
  --proxy-urls /root/mihomo-proxy-urls.txt \
  --bind-address 0.0.0.0
```
