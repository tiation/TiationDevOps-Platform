#!/bin/bash
set -e

echo "🛠️ SXC Server Setup: Creating SSH key if needed..."

# 1. Generate SSH key if missing
if [ ! -f "$HOME/.ssh/id_rsa" ]; then
  ssh-keygen -t rsa -b 4096 -N "" -f "$HOME/.ssh/id_rsa"
fi

# 2. Declare your servers (hostname alias, user@ip, optional IPv6)
declare -A SERVERS
SERVERS=(
  [helm]="root@145.223.21.248"
  [docker]="root@145.223.22.7"
  [docker2]="root@145.223.22.9"
  [gitlab]="root@145.223.22.10"
  [grafana]="root@153.92.214.1"
  [elastic]="root@145.223.22.14"
  [supabase]="root@93.127.167.157"
  [ubuntu]="root@89.116.191.60"
)

echo "📦 Copying SSH key to servers..."

for name in "${!SERVERS[@]}"; do
  ip="${SERVERS[$name]}"
  echo "🔑 Installing key on $name ($ip)..."
  ssh-copy-id -o StrictHostKeyChecking=no "$ip"
done

echo "🧾 Creating ~/.ssh/config aliases..."

for name in "${!SERVERS[@]}"; do
  ip="${SERVERS[$name]#*@}"  # strip user@
  echo -e "\nHost $name\n  HostName $ip\n  User root\n  IdentitiesOnly yes" >> ~/.ssh/config
done

echo "✅ Setup complete! You can now run:"
echo "   ssh helm"
echo "   ssh docker"
