#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  sudo bash mihomo/deploy-mihomo.sh --proxy-urls /path/to/proxy-urls.txt

Options:
  --proxy-urls FILE          File containing one share URL per line. Required.
  --mixed-port PORT          Local mixed HTTP/SOCKS port. Default: 7890.
  --bind-address ADDRESS     Listen address. Default: 127.0.0.1.
  --external-controller ADDR External controller address. Default: 127.0.0.1:9090.
  --no-systemd               Install files and validate config without enabling service.
  -h, --help                 Show this help.

Environment:
  MIHOMO_VERSION             Release tag to install, for example v1.19.13. Defaults to latest.
  MIHOMO_RULE_SOURCE_DIR     Directory containing converted rule provider YAML files.
  MIHOMO_SKIP_BINARY_INSTALL Set to 1 to reuse an existing /usr/local/bin/mihomo.
USAGE
}

log() {
  printf '[mihomo-deploy] %s\n' "$*"
}

die() {
  printf '[mihomo-deploy] ERROR: %s\n' "$*" >&2
  exit 1
}

if [ "$(id -u)" -ne 0 ]; then
  exec sudo -E bash "$0" "$@"
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RULE_SOURCE_DIR="${MIHOMO_RULE_SOURCE_DIR:-$SCRIPT_DIR/rules}"
PROXY_URLS_FILE=""
MIXED_PORT="7890"
BIND_ADDRESS="127.0.0.1"
EXTERNAL_CONTROLLER="127.0.0.1:9090"
ENABLE_SYSTEMD="1"
CONFIG_DIR="/etc/mihomo"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
SERVICE_FILE="/etc/systemd/system/mihomo.service"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --proxy-urls)
      PROXY_URLS_FILE="${2:-}"
      shift 2
      ;;
    --mixed-port)
      MIXED_PORT="${2:-}"
      shift 2
      ;;
    --bind-address)
      BIND_ADDRESS="${2:-}"
      shift 2
      ;;
    --external-controller)
      EXTERNAL_CONTROLLER="${2:-}"
      shift 2
      ;;
    --no-systemd)
      ENABLE_SYSTEMD="0"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[ -n "$PROXY_URLS_FILE" ] || die "--proxy-urls is required"
[ -f "$PROXY_URLS_FILE" ] || die "proxy URL file not found: $PROXY_URLS_FILE"
[ -d "$RULE_SOURCE_DIR" ] || die "rule source directory not found: $RULE_SOURCE_DIR"
find "$RULE_SOURCE_DIR" -name '*.yaml' -type f | grep -q . || die "no .yaml rules found in $RULE_SOURCE_DIR"

install_packages() {
  missing=""
  for cmd in curl gzip grep install python3; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing="$missing $cmd"
    fi
  done
  [ -n "$missing" ] || return 0

  log "Installing missing dependencies:$missing"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gzip grep coreutils python3
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y ca-certificates curl gzip grep coreutils python3
  elif command -v yum >/dev/null 2>&1; then
    yum install -y ca-certificates curl gzip grep coreutils python3
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache ca-certificates curl gzip grep coreutils python3
  else
    die "cannot install dependencies automatically on this system"
  fi
}

detect_asset_pattern() {
  case "$(uname -m)" in
    x86_64|amd64)
      printf 'mihomo-linux-amd64-compatible-[^"]*\\.gz'
      ;;
    aarch64|arm64)
      printf 'mihomo-linux-arm64-[^"]*\\.gz'
      ;;
    armv7l|armv7*)
      printf 'mihomo-linux-armv7-[^"]*\\.gz'
      ;;
    *)
      die "unsupported architecture: $(uname -m)"
      ;;
  esac
}

install_mihomo_binary() {
  if [ "${MIHOMO_SKIP_BINARY_INSTALL:-0}" = "1" ]; then
    [ -x /usr/local/bin/mihomo ] || die "MIHOMO_SKIP_BINARY_INSTALL=1 but /usr/local/bin/mihomo is missing"
    log "Reusing existing mihomo binary"
    /usr/local/bin/mihomo -v | head -n 1
    return 0
  fi

  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT

  version="${MIHOMO_VERSION:-latest}"
  if [ "$version" = "latest" ]; then
    release_api="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
  else
    release_api="https://api.github.com/repos/MetaCubeX/mihomo/releases/tags/$version"
  fi

  log "Resolving mihomo release asset"
  curl --connect-timeout 15 --max-time 120 -fsSL "$release_api" -o "$tmpdir/release.json"
  asset_pattern="$(detect_asset_pattern)"
  asset_url="$(grep -Eo 'https://[^"]+'"$asset_pattern" "$tmpdir/release.json" | head -n 1 || true)"
  if [ -z "$asset_url" ] && [ "$(uname -m)" = "x86_64" ]; then
    asset_url="$(grep -Eo 'https://[^"]+mihomo-linux-amd64-[^"]*\.gz' "$tmpdir/release.json" | head -n 1 || true)"
  fi
  [ -n "$asset_url" ] || die "could not find a matching mihomo release asset"

  log "Downloading mihomo binary"
  curl --connect-timeout 15 --max-time 180 -fL "$asset_url" -o "$tmpdir/mihomo.gz"
  gzip -dc "$tmpdir/mihomo.gz" > "$tmpdir/mihomo"
  install -m 0755 "$tmpdir/mihomo" /usr/local/bin/mihomo
  /usr/local/bin/mihomo -v | head -n 1
}

install_rules() {
  install -d -m 0755 "$CONFIG_DIR/rules"
  install -m 0644 "$RULE_SOURCE_DIR"/*.yaml "$CONFIG_DIR/rules/"
}

generate_config() {
  install -d -m 0755 "$CONFIG_DIR"
  export PROXY_URLS_FILE CONFIG_FILE MIXED_PORT BIND_ADDRESS EXTERNAL_CONTROLLER
  python3 - <<'PY'
import base64
import json
import os
import re
import sys
import urllib.parse
from pathlib import Path

proxy_file = Path(os.environ["PROXY_URLS_FILE"])
config_file = Path(os.environ["CONFIG_FILE"])
mixed_port = int(os.environ["MIXED_PORT"])
bind_address = os.environ["BIND_ADDRESS"]
external_controller = os.environ["EXTERNAL_CONTROLLER"]

def truthy(value):
    return str(value or "").lower() in {"1", "true", "yes", "on"}

def first(query, *keys, default=""):
    for key in keys:
        if key in query and query[key]:
            return query[key][0]
    return default

def split_csv(value):
    return [part for part in str(value or "").split(",") if part]

def unique_name(raw, used, fallback):
    name = urllib.parse.unquote(raw or "").strip() or fallback
    base = re.sub(r"[\r\n\t]+", " ", name).strip() or fallback
    candidate = base
    index = 2
    while candidate in used:
        candidate = f"{base}-{index}"
        index += 1
    used.add(candidate)
    return candidate

def parse_port(parsed):
    if parsed.port is None:
        raise ValueError("missing port")
    return int(parsed.port)

def parse_vmess(url, used):
    raw = url[len("vmess://"):]
    raw += "=" * (-len(raw) % 4)
    data = json.loads(base64.urlsafe_b64decode(raw.encode()).decode())
    name = unique_name(data.get("ps"), used, "vmess")
    proxy = {
        "name": name,
        "type": "vmess",
        "server": data["add"],
        "port": int(data["port"]),
        "uuid": data["id"],
        "alterId": int(data.get("aid") or 0),
        "cipher": data.get("scy") or "auto",
        "udp": True,
        "tls": str(data.get("tls") or "").lower() == "tls",
        "network": data.get("net") or "tcp",
    }
    if data.get("net") == "ws":
        path = data.get("path") or "/"
        if not path.startswith("/"):
            path = "/" + path
        headers = {}
        if data.get("host"):
            headers["Host"] = data["host"]
        proxy["ws-opts"] = {"path": path}
        if headers:
            proxy["ws-opts"]["headers"] = headers
    if data.get("sni"):
        proxy["servername"] = data["sni"]
    return proxy

def parse_vless(url, used):
    parsed = urllib.parse.urlparse(url)
    query = urllib.parse.parse_qs(parsed.query)
    name = unique_name(parsed.fragment, used, "vless")
    proxy = {
        "name": name,
        "type": "vless",
        "server": parsed.hostname,
        "port": parse_port(parsed),
        "uuid": urllib.parse.unquote(parsed.username or ""),
        "udp": True,
        "tls": first(query, "security") in {"tls", "reality"},
        "network": first(query, "type", default="tcp"),
    }
    flow = first(query, "flow")
    if flow:
        proxy["flow"] = flow
    sni = first(query, "sni", "servername", "serverName")
    if sni:
        proxy["servername"] = sni
    fingerprint = first(query, "fp", "fingerprint")
    if fingerprint:
        proxy["client-fingerprint"] = fingerprint
    if first(query, "security") == "reality":
        reality_opts = {}
        public_key = first(query, "pbk", "public-key")
        short_id = first(query, "sid", "short-id")
        if public_key:
            reality_opts["public-key"] = public_key
        if short_id:
            reality_opts["short-id"] = short_id
        if reality_opts:
            proxy["reality-opts"] = reality_opts
    if proxy["network"] == "ws":
        path = first(query, "path", default="/")
        headers = {}
        host = first(query, "host")
        if host:
            headers["Host"] = host
        proxy["ws-opts"] = {"path": path}
        if headers:
            proxy["ws-opts"]["headers"] = headers
    return proxy

def parse_hysteria2(url, used):
    parsed = urllib.parse.urlparse(url)
    query = urllib.parse.parse_qs(parsed.query)
    name = unique_name(parsed.fragment, used, "hysteria2")
    proxy = {
        "name": name,
        "type": "hysteria2",
        "server": parsed.hostname,
        "port": parse_port(parsed),
        "password": urllib.parse.unquote(parsed.username or ""),
        "udp": True,
    }
    sni = first(query, "sni")
    if sni:
        proxy["sni"] = sni
    alpn = split_csv(first(query, "alpn"))
    if alpn:
        proxy["alpn"] = alpn
    if truthy(first(query, "insecure", "allowInsecure", "allow_insecure")):
        proxy["skip-cert-verify"] = True
    return proxy

def parse_tuic(url, used):
    parsed = urllib.parse.urlparse(url)
    query = urllib.parse.parse_qs(parsed.query)
    name = unique_name(parsed.fragment, used, "tuic")
    proxy = {
        "name": name,
        "type": "tuic",
        "server": parsed.hostname,
        "port": parse_port(parsed),
        "uuid": urllib.parse.unquote(parsed.username or ""),
        "password": urllib.parse.unquote(parsed.password or ""),
        "udp": True,
    }
    congestion = first(query, "congestion_control", "congestion-controller")
    if congestion:
        proxy["congestion-controller"] = congestion
    relay = first(query, "udp_relay_mode", "udp-relay-mode")
    if relay:
        proxy["udp-relay-mode"] = relay
    sni = first(query, "sni")
    if sni:
        proxy["sni"] = sni
    alpn = split_csv(first(query, "alpn"))
    if alpn:
        proxy["alpn"] = alpn
    if truthy(first(query, "insecure", "allowInsecure", "allow_insecure")):
        proxy["skip-cert-verify"] = True
    return proxy

def parse_anytls(url, used):
    parsed = urllib.parse.urlparse(url)
    query = urllib.parse.parse_qs(parsed.query)
    name = unique_name(parsed.fragment, used, "anytls")
    proxy = {
        "name": name,
        "type": "anytls",
        "server": parsed.hostname,
        "port": parse_port(parsed),
        "password": urllib.parse.unquote(parsed.username or ""),
        "udp": True,
    }
    sni = first(query, "sni")
    if sni:
        proxy["sni"] = sni
    if truthy(first(query, "insecure", "allowInsecure", "allow_insecure")):
        proxy["skip-cert-verify"] = True
    return proxy

parsers = {
    "vmess": parse_vmess,
    "vless": parse_vless,
    "hysteria2": parse_hysteria2,
    "hy2": parse_hysteria2,
    "tuic": parse_tuic,
    "anytls": parse_anytls,
}

urls = []
for raw in proxy_file.read_text(encoding="utf-8").splitlines():
    line = raw.strip()
    if line and not line.startswith("#"):
        urls.append(line)

used_names = set()
proxies = []
for url in urls:
    scheme = urllib.parse.urlparse(url).scheme
    if scheme not in parsers:
        raise ValueError(f"unsupported proxy scheme: {scheme}")
    proxies.append(parsers[scheme](url, used_names))

if not proxies:
    raise ValueError("no proxy URLs found")

proxy_names = [proxy["name"] for proxy in proxies]
config = {
    "mixed-port": mixed_port,
    "bind-address": bind_address,
    "allow-lan": bind_address not in {"127.0.0.1", "localhost", "::1"},
    "mode": "rule",
    "log-level": "info",
    "ipv6": True,
    "unified-delay": True,
    "tcp-concurrent": True,
    "external-controller": external_controller,
    "profile": {
        "store-selected": True,
        "store-fake-ip": True,
    },
    "dns": {
        "enable": True,
        "listen": "127.0.0.1:1053",
        "ipv6": False,
        "enhanced-mode": "fake-ip",
        "fake-ip-range": "198.18.0.1/16",
        "nameserver": [
            "https://dns.alidns.com/dns-query",
            "https://doh.pub/dns-query",
        ],
        "fallback": [
            "https://dns.google/dns-query",
            "https://cloudflare-dns.com/dns-query",
        ],
        "fake-ip-filter": [
            "*.lan",
            "*.local",
            "localhost.ptlogin2.qq.com",
        ],
    },
    "sniffer": {
        "enable": True,
        "sniff": {
            "HTTP": {
                "ports": ["80", "8080-8880"],
                "override-destination": True,
            },
            "TLS": {
                "ports": ["443", "8443"],
            },
            "QUIC": {
                "ports": ["443", "8443"],
            },
        },
    },
    "proxies": proxies,
    "proxy-groups": [
        {
            "name": "PROXY",
            "type": "select",
            "proxies": ["AUTO"] + proxy_names,
        },
        {
            "name": "AUTO",
            "type": "url-test",
            "proxies": proxy_names,
            "url": "https://www.gstatic.com/generate_204",
            "interval": 300,
            "tolerance": 50,
        },
    ],
    "rule-providers": {
        "remote-cn-direct": {
            "type": "file",
            "behavior": "classical",
            "path": "./rules/remote-cn-direct.yaml",
        },
        "ai-proxy": {
            "type": "file",
            "behavior": "classical",
            "path": "./rules/ai-proxy.yaml",
        },
        "social-media": {
            "type": "file",
            "behavior": "classical",
            "path": "./rules/social-media.yaml",
        },
        "china": {
            "type": "file",
            "behavior": "classical",
            "path": "./rules/china.yaml",
        },
    },
    "rules": [
        "AND,((NETWORK,UDP),(DST-PORT,443)),REJECT",
        "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve",
        "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve",
        "IP-CIDR,172.16.0.0/12,DIRECT,no-resolve",
        "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve",
        "IP-CIDR,169.254.0.0/16,DIRECT,no-resolve",
        "IP-CIDR,224.0.0.0/4,DIRECT,no-resolve",
        "IP-CIDR,255.255.255.255/32,DIRECT,no-resolve",
        "IP-CIDR,17.0.0.0/8,DIRECT,no-resolve",
        "IP-CIDR,2620:149::/32,DIRECT,no-resolve",
        "IP-CIDR,2403:300::/32,DIRECT,no-resolve",
        "IP-CIDR,2A01:B740::/32,DIRECT,no-resolve",
        "RULE-SET,remote-cn-direct,DIRECT",
        "RULE-SET,ai-proxy,PROXY",
        "RULE-SET,social-media,PROXY",
        "RULE-SET,china,DIRECT",
        "GEOIP,CN,DIRECT",
        "MATCH,PROXY",
    ],
}

def scalar(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if value is None:
        return "null"
    return json.dumps(str(value), ensure_ascii=False)

def dump_yaml(value, indent=0):
    pad = "  " * indent
    lines = []
    if isinstance(value, dict):
        for key, item in value.items():
            if isinstance(item, (dict, list)):
                if item:
                    lines.append(f"{pad}{key}:")
                    lines.extend(dump_yaml(item, indent + 1))
                else:
                    lines.append(f"{pad}{key}: []")
            else:
                lines.append(f"{pad}{key}: {scalar(item)}")
    elif isinstance(value, list):
        for item in value:
            if isinstance(item, (dict, list)):
                lines.append(f"{pad}-")
                lines.extend(dump_yaml(item, indent + 1))
            else:
                lines.append(f"{pad}- {scalar(item)}")
    else:
        lines.append(f"{pad}{scalar(value)}")
    return lines

config_file.write_text("\n".join(dump_yaml(config)) + "\n", encoding="utf-8")
print(f"Generated {config_file} with {len(proxies)} proxies.")
PY
}

install_service() {
  cat > "$SERVICE_FILE" <<'SERVICE'
[Unit]
Description=Mihomo proxy service
Documentation=https://github.com/MetaCubeX/mihomo
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/mihomo -d /etc/mihomo -f /etc/mihomo/config.yaml
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SERVICE
  systemctl daemon-reload
  systemctl enable --now mihomo
}

install_packages
install_mihomo_binary
install_rules
generate_config
log "Validating mihomo config"
/usr/local/bin/mihomo -t -d "$CONFIG_DIR" -f "$CONFIG_FILE"

if [ "$ENABLE_SYSTEMD" = "1" ]; then
  install_service
  systemctl --no-pager --full status mihomo
else
  log "Skipped systemd enable/start because --no-systemd was provided"
fi
