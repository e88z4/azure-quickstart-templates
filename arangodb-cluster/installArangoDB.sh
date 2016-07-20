#!/bin/bash

if [ "$#" -lt 4 ]; then
  echo "Usage: $0 <username> <password> <dns-prefix> <count>"
  exit 1
fi

USERNAME=$1
shift

PASSWORD=$1
shift

if [ $2 -lt 4 ]; then
  echo "Need at least 4 servers!"
  exit 3
fi

sudo apt-get update
yes | sudo apt-get install sshpass

i=0
ips=()
while [ $i -lt $2 ]; do
  ip=$(getent hosts "$1$i" | awk '{ print $1 ; exit }')
  if [ "$ip" = "" ]; then
    echo "Couldn't resolve $1$i"
    exit 2
  fi
  
  RESULT=1
  while true; do
    echo "Trying to reach $ip..."
    sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no $USERNAME@$ip ls &>/dev/null
    RESULT=$?
    if [ "$RESULT" = "0" ]; then
      break
    else
      sleep 1
    fi
  done
  ips+=($ip)
  let i=$i+1
done

set -- ${ips[@]}

cat <<EOF >/tmp/install.sh
apt-get update
yes | apt-get install wget apt-transport-https
wget https://www.arangodb.com/repositories/arangodb3/xUbuntu_16.04/Release.key
apt-key add - < Release.key

echo 'deb https://www.arangodb.com/repositories/arangodb3/xUbuntu_16.04/ /' | tee /etc/apt/sources.list.d/arangodb.list
RESULT=1
while true; do
  apt-get update
  if [ "\$?" = "0" ]; then
    break
  fi
  sleep 1
  echo "Retrying apt-get update!"
done
echo arangodb3 arangodb/password password | debconf-set-selections
echo arangodb3 arangodb/password_again password | debconf-set-selections
while true; do
  yes | apt-get install arangodb3
  if [ "\$?" = "0" ]; then
    break
  fi
  sleep 1
  echo "Retrying apt-get install!"
done
/etc/init.d/arangodb3 stop
rm /etc/rc*.d/*arangodb3
rm /etc/init.d/arangodb3
EOF

cat <<EOF >/tmp/base.conf
[server]
endpoint = tcp://0.0.0.0:8529
authentication = false
statistics = true
threads = 16

[scheduler]
threads = 3

[database]
directory = /var/lib/arangodb3

[javascript]
startup-directory = /usr/share/arangodb3/js
app-path = /var/lib/arangodb3-apps

[log]
level = info
EOF

cat <<EOF >/tmp/prepare_agent.sh
mkdir -p /var/lib/arangodb3-agent
mkdir -p /var/lib/arangodb3-agent-apps

chown arangodb.arangodb /var/lib/arangodb3-agent
chown arangodb.arangodb /var/lib/arangodb3-agent-apps
EOF

cat <<EOF >/tmp/prepare_combo_server.sh
mkdir -p /var/lib/arangodb3-coordinator
mkdir -p /var/lib/arangodb3-coordinator-apps
mkdir -p /var/lib/arangodb3-dbserver
mkdir -p /var/lib/arangodb3-dbserver-apps

chown arangodb.arangodb /var/lib/arangodb3-coordinator
chown arangodb.arangodb /var/lib/arangodb3-coordinator-apps
chown arangodb.arangodb /var/lib/arangodb3-dbserver
chown arangodb.arangodb /var/lib/arangodb3-dbserver-apps
EOF

start_systemd() {
  cat <<EOF >/tmp/systemd-$3.service
[Unit]
Description=ArangoDB $2
After=network.target auditd.service

[Service]
ExecStart=/usr/sbin/arangod --uid arangodb --gid arangodb -c $4
ExecReload=/bin/kill -HUP $MAINPID
KillMode=process
RestartPreventExitStatus=255

[Install]
WantedBy=multi-user.target
EOF

  cat <<EOF >/tmp/enable-systemd-$3.sh
chown root.root /tmp/arangodb-$3.service
cp /tmp/arangodb-$3.service /etc/systemd/system/arangodb-$3.service
chmod 664 /etc/systemd/system/arangodb-$3.service
systemctl daemon-reload
systemctl enable arangodb-$3
systemctl restart arangodb-$3
EOF

  sshpass -p "$PASSWORD" scp -o StrictHostKeyChecking=no /tmp/systemd-$3.service $USERNAME@$1:/tmp/arangodb-$3.service
  sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no $USERNAME@$1 'sudo bash -s' < /tmp/enable-systemd-$3.sh
}

deploy_agent() {
  cp /tmp/base.conf /tmp/agency-$1.conf
  cat <<EOF >>/tmp/agency-$1.conf
[agency]
supervision = true
size = 3
id = $2
notify = true
endpoint = $3
endpoint = $4
endpoint = $5
[database]
directory = /var/lib/arangodb3-agent
[javascript]
app-path = /var/lib/arangodb3-agent-apps
EOF

  sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no $USERNAME@$1 'sudo bash -s' < /tmp/install.sh
  sshpass -p "$PASSWORD" scp -o StrictHostKeyChecking=no /tmp/agency-$1.conf $USERNAME@$1:/tmp/arangodb-agent.conf
  sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no $USERNAME@$1 'sudo bash -s' < /tmp/prepare_agent.sh
  sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no $USERNAME@$1 'sudo mv /tmp/arangodb-agent.conf /etc/arangodb3/arangodb-agent.conf && sudo chown root.root /etc/arangodb3/arangodb-agent.conf'
  start_systemd $1 "Agent" "agent" /etc/arangodb3/arangodb-agent.conf
}

deploy_combo_server() {
  cp /tmp/base.conf /tmp/coordinator-$1.conf
  cp /tmp/base.conf /tmp/dbserver-$1.conf
  
  cat <<EOF >>/tmp/coordinator-$1.conf
[server]
threads = 60
[scheduler]
threads = 4
[cluster]
my-role = COORDINATOR
my-address = tcp://$1:8529
my-local-info = $1-coordinator
cluster.agency-endpoint = $2
[database]
directory = /var/lib/arangodb3-coordinator
[javascript]
app-path = /var/lib/arangodb3-coordinator-apps
EOF
  
cat <<EOF >>/tmp/dbserver-$1.conf
[server]
threads = 5
[scheduler]
threads = 3
[cluster]
my-role = PRIMARY
my-address = tcp://$1:8530
my-local-info = $1-dbserver
cluster.agency-endpoint = $2
[database]
directory = /var/lib/arangodb3-dbserver
[javascript]
app-path = /var/lib/arangodb3-dbserver-apps
EOF
  sed -i -e 's/^endpoint.*/endpoint = tcp:\/\/0.0.0.0:8530/g' /tmp/dbserver-$1.conf
  
  sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no $USERNAME@$1 'sudo bash -s' < /tmp/install.sh
  sshpass -p "$PASSWORD" scp -o StrictHostKeyChecking=no /tmp/coordinator-$1.conf $USERNAME@$1:/tmp/arangodb-coordinator.conf
  sshpass -p "$PASSWORD" scp -o StrictHostKeyChecking=no /tmp/dbserver-$1.conf $USERNAME@$1:/tmp/arangodb-dbserver.conf
  sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no $USERNAME@$1 'sudo bash -s' < /tmp/prepare_combo_server.sh
  sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no $USERNAME@$1 'sudo mv /tmp/arangodb-coordinator.conf /etc/arangodb3/arangodb-coordinator.conf'
  sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no $USERNAME@$1 'sudo mv /tmp/arangodb-dbserver.conf /etc/arangodb3/arangodb-dbserver.conf'

  start_systemd $1 "Coordinator" "coordinator" /etc/arangodb3/arangodb-coordinator.conf
  start_systemd $1 "DBServer" "dbserver" /etc/arangodb3/arangodb-dbserver.conf
}

AGENCY_ENDPOINT=tcp://$1:8529

deploy_agent $1 0 tcp://$1:8529 tcp://$2:8529 tcp://$3:8529 &
deploy_agent $2 1 tcp://$1:8529 tcp://$2:8529 tcp://$3:8529 &
deploy_agent $3 2 tcp://$1:8529 tcp://$2:8529 tcp://$3:8529 &

shift
shift
shift

while [ $# -gt 0 ]; do
  deploy_combo_server $1 $AGENCY_ENDPOINT &
  shift
done

wait
