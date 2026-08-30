#!/usr/bin/env bash
# 通过 mihomo 拉取订阅、启动本地代理并探测可用节点。
# 环境变量:
#   PROXY_NODE_URI          单节点 trojan:// 或 vless:// 链接（优先使用）
#   PROXY_SUBSCRIPTION_URL  订阅链接（必填才启用）
#   PROXY_TEST_URL          探测目标，默认 https://www.google.com/generate_204
#   PROXY_REQUIRED          true 时探测失败则退出 1
#   PROXY_PORT              本地 mixed-port，默认 7890
#   PROXY_NODE_NAME         可选，固定选择的节点名称；为空时自动测速

set -euo pipefail

if [[ -z "${PROXY_NODE_URI:-}" && -z "${PROXY_SUBSCRIPTION_URL:-}" ]]; then
	echo "[INFO] PROXY_NODE_URI and PROXY_SUBSCRIPTION_URL not set, skip proxy setup"
	exit 0
fi

PROXY_DIR="${RUNNER_TEMP:-/tmp}/checkin-proxy"
PROXY_PORT="${PROXY_PORT:-7890}"
PROXY_TEST_URL="${PROXY_TEST_URL:-https://www.google.com/generate_204}"
MIHOMO_VERSION="${MIHOMO_VERSION:-v1.19.0}"
PROXY_REQUIRED="${PROXY_REQUIRED:-false}"
PROXY_NODE_NAME="${PROXY_NODE_NAME:-}"
export PROXY_NODE_NAME
HEALTH_TIMEOUT=20
HEALTH_ATTEMPTS=45
if [[ -n "${PROXY_NODE_NAME}" ]]; then
	HEALTH_TIMEOUT=8
	HEALTH_ATTEMPTS=12
fi

mkdir -p "${PROXY_DIR}"
cd "${PROXY_DIR}"

if [[ -n "${PROXY_NODE_URI:-}" ]]; then
	echo "[INFO] Converting single proxy URI..."
	if ! ruby -ryaml -ruri -e '
    raw = ENV.fetch("PROXY_NODE_URI")
    uri = URI.parse(raw)
    abort "only trojan:// and vless:// are supported" unless %w[trojan vless].include?(uri.scheme)
    abort "proxy URI is missing host or port" unless uri.host && uri.port

    params = URI.decode_www_form(uri.query.to_s).to_h
    decode = ->(value) { URI.decode_www_form_component(value.to_s) }
    truthy = ->(value) { %w[1 true yes].include?(value.to_s.downcase) }
    network = params.fetch("type", "tcp")
    security = params.fetch("security", uri.scheme == "trojan" ? "tls" : "none")
    credential = decode.call(uri.userinfo)
    abort "proxy URI is missing credentials" if credential.empty?

    proxy = {
      "name" => decode.call(uri.fragment || "#{uri.scheme}-node"),
      "type" => uri.scheme,
      "server" => uri.host,
      "port" => uri.port,
      uri.scheme == "vless" ? "uuid" : "password" => credential,
      "udp" => true
    }
    proxy["network"] = network unless network == "tcp"
    proxy["tls"] = true if %w[tls reality].include?(security)
    proxy["servername"] = params["sni"] if params["sni"] && !params["sni"].empty?
    proxy["skip-cert-verify"] = truthy.call(params["allowInsecure"] || params["insecure"])
    proxy["client-fingerprint"] = params["fp"] if params["fp"] && !params["fp"].empty?
    proxy["flow"] = params["flow"] if params["flow"] && !params["flow"].empty?
    proxy["alpn"] = params["alpn"].split(",") if params["alpn"] && !params["alpn"].empty?

    if security == "reality"
      proxy["reality-opts"] = {
        "public-key" => params["pbk"],
        "short-id" => params["sid"].to_s
      }
    end
    if network == "ws"
      proxy["ws-opts"] = {"path" => decode.call(params.fetch("path", "/"))}
      proxy["ws-opts"]["headers"] = {"Host" => params["host"]} if params["host"] && !params["host"].empty?
    elsif network == "grpc"
      service = params["serviceName"] || params["service-name"]
      proxy["grpc-opts"] = {"grpc-service-name" => service} if service && !service.empty?
    end

    File.write("subscription.yaml", {"proxies" => [proxy]}.to_yaml)
  '; then
		echo "[FAILED] PROXY_NODE_URI is not a compatible trojan:// or vless:// link"
		if [[ "${PROXY_REQUIRED}" == "true" ]]; then
			exit 1
		fi
		exit 0
	fi
else
	echo "[INFO] Downloading subscription..."
	if ! curl --retry 3 --retry-delay 5 --retry-all-errors -fsSL -o source-subscription.yaml "${PROXY_SUBSCRIPTION_URL}"; then
		echo "[FAILED] Failed to download subscription"
		if [[ "${PROXY_REQUIRED}" == "true" ]]; then
			exit 1
		fi
		exit 0
	fi

	# Convert either a full Clash config or a provider response into a provider-only file.
	if ! ruby -ryaml -e '
    source = YAML.safe_load(File.read("source-subscription.yaml"), aliases: true)
    proxies = source.is_a?(Hash) ? source["proxies"] : nil
    abort "subscription has no proxies list" unless proxies.is_a?(Array) && !proxies.empty?
    if (wanted = ENV["PROXY_NODE_NAME"]) && !wanted.empty?
      proxies = proxies.select { |proxy| proxy.is_a?(Hash) && proxy["name"] == wanted }
      abort "requested proxy node was not found" if proxies.empty?
    end
    File.write("subscription.yaml", {"proxies" => proxies}.to_yaml)
  '; then
		echo "[FAILED] Subscription is not a compatible Clash/Mihomo YAML response"
		if [[ "${PROXY_REQUIRED}" == "true" ]]; then
			exit 1
		fi
		exit 0
	fi
fi

echo "[INFO] Downloading mihomo ${MIHOMO_VERSION}..."
ARCHIVE="mihomo-linux-amd64-${MIHOMO_VERSION}.gz"
if ! curl --retry 3 --retry-delay 5 --retry-all-errors -fsSL -o "${ARCHIVE}" \
	"https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/${ARCHIVE}"; then
	echo "[WARN] Failed to download mihomo ${MIHOMO_VERSION}, skip proxy setup"
	if [[ "${PROXY_REQUIRED}" == "true" ]]; then
		exit 1
	fi
	exit 0
fi
gunzip -f "${ARCHIVE}"
chmod +x "mihomo-linux-amd64-${MIHOMO_VERSION}"
MIHOMO_BIN="${PROXY_DIR}/mihomo-linux-amd64-${MIHOMO_VERSION}"

cat > config.yaml <<EOF
mixed-port: ${PROXY_PORT}
allow-lan: false
ipv6: false
mode: rule
log-level: warning
unified-delay: true

proxy-providers:
  subscription:
    type: file
    path: ./subscription.yaml
    health-check:
      enable: true
      interval: 300
      url: https://www.gstatic.com/generate_204

proxy-groups:
  - name: CHECKIN
    type: url-test
    url: "${PROXY_TEST_URL}"
    interval: 300
    tolerance: 150
    lazy: false
    use:
      - subscription
EOF

cat >> config.yaml <<EOF

rules:
  - MATCH,CHECKIN
EOF

echo "[INFO] Starting mihomo on 127.0.0.1:${PROXY_PORT}..."
nohup "${MIHOMO_BIN}" -d "${PROXY_DIR}" -f config.yaml > mihomo.log 2>&1 &
echo $! > mihomo.pid

PROXY_URL="http://127.0.0.1:${PROXY_PORT}"
READY=false
for attempt in $(seq 1 "${HEALTH_ATTEMPTS}"); do
	if curl -fsS -x "${PROXY_URL}" --max-time "${HEALTH_TIMEOUT}" "${PROXY_TEST_URL}" -o /dev/null 2>/dev/null; then
		READY=true
		break
	fi
	echo "[INFO] Waiting for proxy health check (${attempt}/${HEALTH_ATTEMPTS})..."
	sleep 2
done

if [[ "${READY}" != "true" ]]; then
	echo "[FAILED] Proxy health check failed for ${PROXY_TEST_URL}"
	tail -n 30 mihomo.log || true
	if [[ -f mihomo.pid ]]; then
		kill "$(cat mihomo.pid)" 2>/dev/null || true
	fi
	if [[ "${PROXY_REQUIRED}" == "true" ]]; then
		exit 1
	fi
	exit 0
fi

echo "[SUCCESS] Proxy is ready: ${PROXY_URL}"
echo "[INFO] Proxy is scoped to CHECKIN_PROXY_URL (browser/python only, not global HTTP_PROXY)"
if [[ -n "${GITHUB_ENV:-}" ]]; then
	echo "CHECKIN_PROXY_URL=${PROXY_URL}" >> "${GITHUB_ENV}"
fi
