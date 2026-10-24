#!/usr/bin/env bash
# 显示本机 1～指定最大端口（默认 10000）已监听/绑定的 TCP、UDP 端口及对应程序。
# 对 docker-proxy 额外显示 Docker 容器名称（需能访问本机 Docker daemon）。
# 用法：sudo ./ports.sh [最大端口]；例如 sudo ./ports.sh 9000
# 依赖：bash、ss (iproute2)、awk、sort；Docker 信息查询需 docker 命令。
set -euo pipefail

# 可选参数：最大端口。无参数时默认为 10000。
if (( $# > 1 )); then
    echo "用法: $0 [最大端口]（范围 1～65535，默认 10000）" >&2
    exit 2
fi
max_port="${1-10000}"
if [[ ! "$max_port" =~ ^[0-9]{1,5}$ ]] || (( 10#$max_port < 1 || 10#$max_port > 65535 )); then
    echo "错误：最大端口必须是 1～65535 之间的整数。" >&2
    exit 2
fi
max_port=$((10#$max_port))

if (( EUID != 0 )); then
    exec sudo -- "$0" "$@"
fi

# 只读取一次端口快照，避免 Docker 查询期间端口状态变化造成错配。
sockets=$(ss -H -lntup)

mapping_file=$(mktemp)
trap 'rm -f "$mapping_file"' EXIT

# 仅在出现 docker-proxy 时查询 Docker。一个 inspect 请求获得所有运行容器的端口映射。
if [[ "$sockets" == *docker-proxy* ]] && command -v docker >/dev/null 2>&1; then
    ids=()
    mapfile -t ids < <(docker ps -q 2>/dev/null || true)
    if (( ${#ids[@]} > 0 )); then
        docker inspect --format '{{ $name := .Name }}{{ range $target, $bindings := .NetworkSettings.Ports }}{{ range $bindings }}{{ printf "%s\t%s\t%s\t%s\n" .HostIp .HostPort $target $name }}{{ end }}{{ end }}' \
            "${ids[@]}" > "$mapping_file" 2>/dev/null || :
    fi
fi

awk -v mapping_file="$mapping_file" -v max_port="$max_port" '
BEGIN {
    # 映射内容：宿主机 IP、宿主机端口、容器端口/协议、容器名称。
    while ((getline line < mapping_file) > 0) {
        n = split(line, parts, "\t")
        if (n != 4) continue
        host_ip = parts[1]
        if (host_ip == "") host_ip = "0.0.0.0"
        host_port = parts[2]
        split(parts[3], target, "/")
        protocol = target[2]
        name = parts[4]
        sub(/^\//, "", name)

        mapping[host_ip SUBSEP host_port SUBSEP protocol] = name
        # 只有同一端口/协议无歧义时，才允许在 IP 不匹配时回退。
        fallback_key = host_port SUBSEP protocol
        if (!(fallback_key in fallback)) fallback[fallback_key] = name
        else if (fallback[fallback_key] != name) fallback[fallback_key] = ""
    }
    close(mapping_file)
}
{
    local_addr = $5
    port = local_addr
    sub(/^.*:/, "", port)
    if (port !~ /^[0-9]+$/) next
    port += 0
    if (port < 1 || port > max_port) next

    local_ip = local_addr
    sub(/:[0-9]+$/, "", local_ip)
    gsub(/^\[|\]$/, "", local_ip)
    protocol = ($1 ~ /^udp/) ? "udp" : "tcp"
    key = local_ip SUBSEP port SUBSEP protocol
    fallback_key = port SUBSEP protocol
    container = (key in mapping) ? mapping[key] : fallback[fallback_key]

    processes = ""
    remaining = $0
    while (match(remaining, /"[^"]+",pid=[0-9]+/)) {
        entry = substr(remaining, RSTART + 1, RLENGTH - 1)
        name = entry
        sub(/",pid=.*/, "", name)
        pid = entry
        sub(/^.*",pid=/, "", pid)

        label = name
        if (name == "docker-proxy" && container != "") {
            label = name " [" container "]"
        }
        label = label " (PID " pid ")"
        if (processes != "") processes = processes ", "
        processes = processes label
        remaining = substr(remaining, RSTART + RLENGTH)
    }
    if (processes == "") processes = "未知程序"

    printf "%d - %s\n", port, processes
}
' <<< "$sockets" | sort -n -k1,1 | uniq
