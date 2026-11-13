#!/bin/sh
# Prepare the bind-mount tree compose.data.yml expects, then seed two things:
#
#   ./data/omp/agent      omp's config root, copied from ~/.omp/agent so the
#                         container's agent reads the same config.yml + models.yml
#                         without sharing a live SQLite file with the host agent.
#   ./data/omb/.openmausbot/config.json
#                         the instance list: the llama-swap gateway models and the
#                         omp agent itself, as a customAcp engine on /opt/omp/omp.
#                         The instance environment is the only env a boxed child keeps.
#
# Nothing here overwrites what already exists. Run it once before `docker compose
# -f compose.data.yml up -d`; the services run as the host user (OMB_UID/OMB_GID,
# 1000 by default), so the tree stays writable without a chown.
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
data="$root/data"
source_agent="${OMP_AGENT_DIR:-$HOME/.omp/agent}"
uid="${OMB_UID:-$(id -u)}"
gid="${OMB_GID:-$(id -g)}"

mkdir -p "$data/omb" "$data/omp/agent" "$data/caddy/data" "$data/caddy/config"
if [ "$(id -u)" = "$uid" ]; then
  chown -R "$uid:$gid" "$data" || echo "chown $data to $uid:$gid failed; run it once with sudo" >&2
fi

# Compose reads .env in this folder. The data root has to be absolute: the daemon that
# starts a bot's desktop container resolves the workspace path on the host, so the server
# and the daemon must see the same path (deploy/podman/README.md).
env_file="$root/.env"
docker_gid="$(getent group docker 2>/dev/null | cut -d: -f3 || true)"
: >> "$env_file"
upsert() {
  if grep -q "^$1=" "$env_file"; then
    sed "s|^$1=.*|$1=$2|" "$env_file" > "$env_file.tmp" && mv "$env_file.tmp" "$env_file"
  else
    printf '%s=%s\n' "$1" "$2" >> "$env_file"
  fi
}
upsert OMB_DATA_ROOT "$data/omb"
upsert OMB_UID "$uid"
upsert OMB_GID "$gid"
if [ -n "$docker_gid" ]; then upsert DOCKER_GID "$docker_gid"; fi
echo "wrote $env_file (OMB_DATA_ROOT=$data/omb${docker_gid:+ DOCKER_GID=$docker_gid})"

# Self-signed certificate for the HTTPS edge (deploy/local/Caddyfile.https). The
# names a browser uses must be inside it, so add the LAN name or address:
#   OMB_HTTPS_NAMES="omb.local 192.168.0.135" ./setup-data.sh
certs="$data/caddy/certs"
if [ -e "$certs/omb.crt" ]; then
  echo "keep $certs/omb.crt"
else
  mkdir -p "$certs"
  names="${OMB_HTTPS_NAMES:-localhost 127.0.0.1}"
  san=""
  for name in $names; do
    case "$name" in
      [0-9]*.[0-9]*.[0-9]*.[0-9]*|*:[0-9]*) san="$san,IP:$name" ;;
      *) san="$san,DNS:$name" ;;
    esac
  done
  san="${san#,}"
  umask 177
  openssl req -x509 -newkey rsa:2048 -sha256 -days 825 -nodes \
    -keyout "$certs/omb.key" -out "$certs/omb.crt" \
    -subj "/CN=${names%% *}" -addext "subjectAltName=$san" >/dev/null 2>&1
  echo "wrote $certs/omb.crt for ${san#,} (825 days); the browser will still warn about the issuer"
fi

for file in config.yml models.yml; do
  [ -f "$source_agent/$file" ] || continue
  if [ -e "$data/omp/agent/$file" ]; then
    echo "keep data/omp/agent/$file"
    continue
  fi
  cp "$source_agent/$file" "$data/omp/agent/$file"
  echo "seeded data/omp/agent/$file from $source_agent"
done
if [ ! -f "$data/omp/agent/models.yml" ]; then
  echo "warning: no models.yml under $source_agent or $data/omp/agent; the omp engine will use its catalog defaults" >&2
fi

config="$data/omb/.openmausbot/config.json"
# The default model is this instance's task role, read off the seeded config.yml.
default_model="$(sed -n 's#^  task: [^/]*/##p' "$data/omp/agent/config.yml" 2>/dev/null | head -1)"
default_model="${LLAMA_SWAP_MODEL:-${default_model:-qwen38-flash-halogen-1M:low-reasoning}}"

if [ -e "$config" ]; then
  echo "$config exists; instance seed skipped"
  exit 0
fi

umask 177
mkdir -p "$(dirname -- "$config")" && chmod 700 "$(dirname -- "$config")"
cat > "$config" <<JSON
{
  "instances": {
    "llama-swap-halo": {
      "driver": "openai-compat",
      "displayName": "llama-swap · models.yml",
      "access": "api",
      "config": { "apiKeyEnv": "OPENAI_COMPAT_API_KEY" }
    },
    "omp": {
      "driver": "customAcp",
      "displayName": "omp agent",
      "environment": { "PI_CODING_AGENT_DIR": "/data/.omp/agent" },
      "config": { "cli": "/opt/omp/omp acp" }
    }
  },
  "defaultModelSelection": {
    "instanceId": "llama-swap-halo",
    "model": "${default_model}"
  }
}
JSON
echo "wrote $config (default model ${default_model}; the url comes from OPENAI_COMPAT_URL)"
