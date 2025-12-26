#!/usr/bin/env bash
# 作用: 生成/更新群晖 WireGuard 服务端配置 ds_wg.conf，并生成或删除对应客户端配置 <name>.conf。
# 用法: ./generate_wg.sh -c <客户端名称>
#       ./generate_wg.sh -d <客户端名称>
# 说明: 服务端私钥/公钥已内置在脚本中；客户端密钥由 wg 生成。
# 关键字段说明:
# - server_private_key/server_public_key: 群晖端 WireGuard 服务端密钥对，必须匹配。
# - client_endpoint: 客户端访问入口（公网IP/域名:端口），需替换为真实地址，端口与服务端监听端口一致。
#
# 用户需配置的三项（放在最上方便于修改）
server_private_key="xxx"
server_public_key="xxx"
client_endpoint="xxx:51820"
set -euo pipefail

usage() {
  cat <<'USAGE'
用法: ./generate_wg.sh -c <客户端名称>
      ./generate_wg.sh -d <客户端名称>
USAGE
}

client_name=""
action=""
while getopts ":c:d:h" opt; do
  case "$opt" in
    c)
      client_name="$OPTARG"
      action="create"
      ;;
    d)
      client_name="$OPTARG"
      action="delete"
      ;;
    h)
      usage
      exit 0
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$client_name" || -z "$action" ]]; then
  usage
  exit 1
fi

# 可根据需要修改以下默认配置
server_address="10.9.0.1/24"
server_listen_port="51820"
client_allowed_ips="192.168.8.0/24, 10.9.0.0/24"
client_keepalive="25"
client_ip_prefix="10.9.0."
client_ip_start="2"

server_conf="ds_wg.conf"
client_conf="${client_name}.conf"

trim_trailing_blank_lines() {
  local file_path="$1"
  awk '
    {
      if ($0 ~ /[^[:space:]]/) {
        last = NR
      }
      lines[NR] = $0
    }
    END {
      for (i = 1; i <= last; i++) {
        print lines[i]
      }
    }
  ' "$file_path" > "${file_path}.tmp"
  mv "${file_path}.tmp" "$file_path"
}

delete_client() {
  local name="$1"
  local conf_path="$2"
  if [[ ! -f "$conf_path" ]]; then
    echo "错误: 未找到 ${conf_path}。" >&2
    exit 1
  fi
  if ! grep -q "^# Client: ${name}$" "$conf_path"; then
    echo "错误: ds_wg.conf 中不存在客户端 ${name}。" >&2
    exit 1
  fi
  read -r -p "确认删除客户端 ${name} 的服务端与客户端配置? [y/N] " answer
  case "${answer:-N}" in
    y|Y)
      ;;
    *)
      echo "已取消。"
      exit 0
      ;;
  esac
  awk -v name="$name" '
    $0 ~ "^# Client: "name"$" {skip=1; next}
    skip && $0 ~ "^# Client: " {skip=0}
    skip {next}
    {print}
  ' "$conf_path" > "${conf_path}.tmp"
  mv "${conf_path}.tmp" "$conf_path"
  trim_trailing_blank_lines "$conf_path"
  if [[ -f "${name}.conf" ]]; then
    rm "${name}.conf"
  fi
  echo "已删除: ${name}"
  exit 0
}

if [[ "$action" == "delete" ]]; then
  delete_client "$client_name" "$server_conf"
fi

if ! command -v wg >/dev/null 2>&1; then
  echo "错误: 未找到 wg 命令，请先安装 WireGuard 工具。" >&2
  exit 1
fi

existing_client_ip=""
if [[ -f "$server_conf" ]]; then
  client_exists=false
  if command -v rg >/dev/null 2>&1; then
    if rg -q "^# Client: ${client_name}$" "$server_conf"; then
      client_exists=true
    fi
  else
    if grep -q "^# Client: ${client_name}$" "$server_conf"; then
      client_exists=true
    fi
  fi
  if [[ "$client_exists" == true ]]; then
    read -r -p "客户端 ${client_name} 已存在，是否覆盖? [y/N] " answer
    case "${answer:-N}" in
      y|Y)
        existing_client_ip="$(awk -v name="$client_name" '
          $0 ~ "^# Client: "name"$" {in_block=1; next}
          in_block && $1 == "AllowedIPs" {print $3; exit}
          in_block && $0 ~ "^# Client: " {exit}
        ' "$server_conf")"
        awk -v name="$client_name" '
          $0 ~ "^# Client: "name"$" {skip=1; next}
          skip && $0 ~ "^# Client: " {skip=0}
          skip {next}
          {print}
        ' "$server_conf" > "${server_conf}.tmp"
        mv "${server_conf}.tmp" "$server_conf"
        ;;
      *)
        echo "已取消。"
        exit 0
        ;;
    esac
  fi
else
  cat <<EOF > "$server_conf"
# Server
[Interface]
PrivateKey = ${server_private_key}
Address = ${server_address}
ListenPort = ${server_listen_port}
EOF
fi

if [[ -z "$existing_client_ip" ]]; then
  used_octets="$(awk -v prefix="$client_ip_prefix" '
    $1 == "AllowedIPs" && $2 == "=" {
      ip = $3
      sub(/\/32$/, "", ip)
      if (index(ip, prefix) == 1) {
        split(ip, parts, ".")
        print parts[4] + 0
      }
    }
  ' "$server_conf" | sort -n)"
  next_octet="$client_ip_start"
  while (( next_octet <= 254 )); do
    if ! printf '%s\n' "$used_octets" | grep -qx "$next_octet"; then
      break
    fi
    next_octet="$((next_octet + 1))"
  done
  if (( next_octet > 254 )); then
    echo "错误: 客户端地址已用尽。" >&2
    exit 1
  fi

  existing_client_ip="${client_ip_prefix}${next_octet}/32"
fi

trim_trailing_blank_lines "$server_conf"

client_private_key="$(wg genkey)"
client_public_key="$(printf '%s' "$client_private_key" | wg pubkey)"
client_preshared_key="$(wg genpsk)"

cat <<EOF >> "$server_conf"

# Client: ${client_name}
[Peer]
PublicKey = ${client_public_key}
PresharedKey = ${client_preshared_key}
AllowedIPs = ${existing_client_ip}
EOF

cat <<EOF > "$client_conf"
[Interface]
PrivateKey = ${client_private_key}
Address = ${existing_client_ip}

[Peer]
PublicKey = ${server_public_key}
PresharedKey = ${client_preshared_key}
AllowedIPs = ${client_allowed_ips}
Endpoint = ${client_endpoint}
PersistentKeepalive = ${client_keepalive}
EOF

echo "已生成: ${server_conf}, ${client_conf}"
