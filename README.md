# 群晖 7.1 WireGuard 配置

本文档说明如何在群晖 7.1 部署 WireGuard，并配套使用脚本生成服务端配置 `ds_wg.conf` 与客户端配置 `<name>.conf`。脚本基于内置的服务端私钥/公钥生成配置，客户端密钥通过 `wg` 命令生成。

## 目录结构

- `generate_wg.sh`：配置生成与删除脚本
- `ds_wg.conf`：群晖服务端 WireGuard 配置（输出）
- `<name>.conf`：客户端配置（输出）

## 环境要求

- 需要安装 WireGuard 工具（提供 `wg` 命令）
- 群晖端需支持 `wg-quick`（或等价管理方式）
- 群晖 DSM 7.1：需先在“套件中心 -> 套件来源”添加第三方源，再安装 WireGuard 套件

### WireGuard 工具说明

- macOS：通常通过 Homebrew 安装 `wireguard-tools` 后可用 `wg` 命令
- Linux：多数发行版提供 `wireguard-tools` 包
- WSL：可在 WSL 的 Linux 发行版内安装 `wireguard-tools`，并确保 `wg` 可用

## 群晖 7.1 安装 WireGuard 套件

1) 打开“套件中心 -> 设置 -> 套件来源”  
2) 点击“新增”，填写：  
- 名称：`spk7`  
- 位置：`spk7.imnks.com/`  
3) 保存后，在套件中心搜索并安装 WireGuard 套件  

## 脚本用法（macOS / Linux / WSL）

生成或更新客户端配置：
```bash
./generate_wg.sh -c <客户端名称>
```

删除客户端配置：
```bash
./generate_wg.sh -d <客户端名称>
```

说明：
- `-c` 会在 `ds_wg.conf` 中追加对应客户端的 `[Peer]` 块，并生成 `<name>.conf`。
- `-d` 会从 `ds_wg.conf` 中移除对应客户端的 `[Peer]` 块，并删除 `<name>.conf`。
- 客户端 IP 从 `10.9.0.2/32` 开始分配，删除后会复用空出的最小可用地址。
- 若客户端名称已存在，会提示是否覆盖；删除时会提示是否确认。

## 群晖部署流程（服务端）

1) 将服务端配置拷贝到群晖（示例用 scp）：
```bash
scp ds_wg.conf <群晖用户名>@<群晖地址>:/etc/wireguard/ds_wg.conf
```

2) 启动 WireGuard：
```bash
sudo wg-quick up ds_wg
```

3) 查看状态：
```bash
sudo wg show
```

4) 停止 WireGuard：
```bash
sudo wg-quick down ds_wg
```

## 客户端配置分发

将生成的 `<name>.conf` 发送到对应客户端导入即可。客户端配置中的 `Endpoint`、`AllowedIPs`、`PersistentKeepalive` 等字段可以在脚本顶部默认配置处调整。

Endpoint 说明（必改）
- 当前脚本默认值为 `xxx:51820`，只是占位符
- 需要替换为你的真实公网地址或 DDNS 域名，例如：`example.com:51820`
- 端口需与群晖 WireGuard 监听端口一致（脚本默认 `51820`）

服务端密钥说明（必改）
- `server_private_key`：群晖服务端私钥，只能放在服务端配置中，不能泄露
- `server_public_key`：服务端公钥，会写入客户端配置的 `[Peer]` 块
- 两者必须是同一对密钥；若不匹配，客户端无法握手

## 配置变更后的处理

当 `ds_wg.conf` 发生变化（新增/删除客户端或调整配置）时：

方式一：重启服务端（通用）
```bash
sudo wg-quick down ds_wg
sudo wg-quick up ds_wg
```

方式二：热更新（需支持 `syncconf` + `strip`）
```bash
sudo wg syncconf ds_wg <(wg-quick strip /etc/wireguard/ds_wg.conf)
```

支持性检查（确认有输出即表示支持）：
```bash
sudo wg --help | grep syncconf
sudo wg-quick --help | grep strip
```

## 注意事项

- 脚本内置服务端私钥/公钥，如果需要更换密钥，请直接修改 `generate_wg.sh` 中的 `server_private_key` 与 `server_public_key`。
- 请妥善保管服务端私钥，避免泄露。
