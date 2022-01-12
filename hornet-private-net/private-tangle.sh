#!/bin/bash

# Script to run a new Private Tangle
# private-tangle.sh install .- Installs a new Private Tangle
# private-tangle.sh start   .- Starts a new Private Tangle
# private-tangle.sh update  .- Updates the Private Tangle
# private-tangle.sh stop    .- Stops the Tangle

set -e

chmod +x ./utils.sh
source ./utils.sh

help () {
  echo "usage: private-tangle.sh [start|stop|update|install] <coo_bootstrap_wait_time?>"
}

if [ $#  -lt 1 ]; then
  echo "Illegal number of parameters"
  help
  exit 1
fi

command="$1"

ip_address=$(echo $(dig +short myip.opendns.com @resolver1.opendns.com))
COO_BOOTSTRAP_WAIT=10

if [ -n "$2" ]; then
  COO_BOOTSTRAP_WAIT="$2"
fi

clean () {
  # TODO: Differentiate between start, restart and remove
  stopContainers

  # We need sudo here as the files are going to be owned by the hornet user
  if [ -f ./db/private-tangle/coordinator.state ]; then
    sudo rm ./db/private-tangle/coordinator.state
  fi

  if [ -d ./db/private-tangle ]; then
    cd ./db/private-tangle
    removeSubfolderContent "coo.db" "node1.db" "node2.db" "spammer1.db" "spammer2.db" "node-autopeering.db"
    cd ../..
  fi

  if [ -d ./p2pstore ]; then
    cd ./p2pstore
    removeSubfolderContent coo node1 node2 spammer1 spammer2 "node-autopeering"
    cd ..
  fi

  if [ -d ./snapshots/private-tangle ]; then
    sudo rm -Rf ./snapshots/private-tangle/*
  fi

  # We need to do this so that initially the permissions are user's permissions
  resetPeeringFile config/peering-node1.json
  resetPeeringFile config/peering-spammer1.json
  resetPeeringFile config/peering-node2.json
  resetPeeringFile config/peering-spammer2.json
}

# Sets up the necessary directories if they do not exist yet
volumeSetup () {
  ## Directories for the Tangle DB files
  if ! [ -d ./db ]; then
    mkdir ./db
  fi

  if ! [ -d ./db/private-tangle ]; then
    mkdir ./db/private-tangle
  fi

  cd ./db/private-tangle
  createSubfolders coo.db spammer1.db spammer2.db node1.db node2.db node-autopeering.db
  cd ../..

  # Snapshots
  if ! [ -d ./snapshots ]; then
    mkdir ./snapshots
  fi

  if ! [ -d ./snapshots/private-tangle ]; then
    mkdir ./snapshots/private-tangle
  fi

  # P2P
  if ! [ -d ./p2pstore ]; then
    mkdir ./p2pstore
  fi

  cd ./p2pstore
  createSubfolders coo spammer1 spammer2 node1 node2 node-autopeering
  cd ..

  ## Change permissions so that the Tangle data can be written (hornet user)
  ## TODO: Check why on MacOS this cause permission problems
  if ! [[ "$OSTYPE" == "darwin"* ]]; then
    echo "Setting permissions for Hornet..."
    sudo chown -R 65532:65532 db 
    sudo chown -R 65532:65532 snapshots 
    sudo chown -R 65532:65532 p2pstore
  fi 
}

installTangle () {
  # First of all volumes have to be set up
  volumeSetup

  clean

  # The network is created to support the containers
  docker network prune -f
  # Ensure the script does not stop if it has not been pruned
  set +e
  docker network create "private-tangle"
  # docker network create --driver overlay "tangle1"
  set -e

  # When we install we ensure container images are updated
  updateContainers

  # Initial snapshot
  generateSnapshot

  # P2P identities are generated
  setupIdentities

  # Peering of the nodes is configured
  setupPeering

  # Autopeering entry node is configured
  setupAutopeering

  # Autopeering entry node is started
  startAutopeering

  # Coordinator set up
  setupCoordinator

  # And finally containers are started
  startContainers
}

startContainers () {
  # Run the coordinator
  docker-compose --log-level ERROR up -d coo

  # Run the spammer
  docker-compose --log-level ERROR up -d spammer1

  # Run the spammer
  docker-compose --log-level ERROR up -d spammer2

  # Run a regular node 
  docker-compose --log-level ERROR up -d node1

    # Run a regular node 
  docker-compose --log-level ERROR up -d node2
}

updateContainers () {
  docker-compose pull
}

updateTangle () {
  if ! [ -f ./snapshots/private-tangle/full_snapshot.bin ]; then
    echo "Install your Private Tangle first with './private-tangle.sh install'"
    exit 129
  fi

  stopContainers

  # We ensure we are now going to run with the latest Hornet version
  image="gohornet\/hornet:latest"
  sed -i 's/image: .\+/image: '$image'/g' docker-compose.yml

  updateContainers

  startTangle
}

### 
### Generates the initial snapshot
### 
generateSnapshot () {
  echo "Generating an initial snapshot..."
    # First a key pair is generated
  docker-compose run --rm node1 hornet tool ed25519-key > key-pair.txt

  # Extract the public key use to generate the address
  local public_key="$(getPublicKey key-pair.txt)"

  # Generate the address
  cat key-pair.txt | awk -F : '{if ($1 ~ /ed25519 address/) print $2}' \
  | sed "s/ \+//g" | tr -d "\n" | tr -d "\r" > address.txt

  # Generate the snapshot
  cd snapshots/private-tangle
  docker-compose run --rm -v "$PWD:/output_dir" node1 hornet tool snap-gen "private-tangle"\
   "$(cat ../../address.txt)" 1000000000 /output_dir/full_snapshot.bin

  echo "Initial Ed25519 Address generated. You can find the keys at key-pair.txt and the address at address.txt"

  cd .. && cd ..
}

###
### Sets the Coordinator up by creating a key pair
###
setupCoordinator () {
  local coo_key_pair_file=coo-milestones-key-pair.txt

  docker-compose run --rm coo hornet tool ed25519-key > "$coo_key_pair_file"
  # Private Key is exported as it is needed to run the Coordinator
  export COO_PRV_KEYS="$(getPrivateKey $coo_key_pair_file)"

  local coo_public_key="$(getPublicKey $coo_key_pair_file)"
  echo "$coo_public_key" > coo-milestones-public-key.txt

  setCooPublicKey "$coo_public_key" config/config-coo.json
  setCooPublicKey "$coo_public_key" config/config-node1.json
  setCooPublicKey "$coo_public_key" config/config-node2.json
  setCooPublicKey "$coo_public_key" config/config-spammer1.json
  setCooPublicKey "$coo_public_key" config/config-spammer2.json

  bootstrapCoordinator
}

# Bootstraps the coordinator
bootstrapCoordinator () {
  echo "Bootstrapping the Coordinator..."
  # Need to do it again otherwise the coo will not bootstrap
  if ! [[ "$OSTYPE" == "darwin"* ]]; then
    sudo chown -R 65532:65532 p2pstore
  fi

  # Bootstrap the coordinator
  docker-compose run -d --rm -e COO_PRV_KEYS=$COO_PRV_KEYS coo hornet --cooBootstrap --cooStartIndex 0 > coo.bootstrap.container

  # Waiting for coordinator bootstrap
  # We guarantee that if bootstrap has not finished yet we sleep another time 
  # for a few seconds more until bootstrap has been performed
  bootstrapped=1
  bootstrap_tick=$COO_BOOTSTRAP_WAIT
  echo "Waiting for $bootstrap_tick seconds ... ⏳"
  sleep $bootstrap_tick
  docker logs $(cat ./coo.bootstrap.container) 2>&1 | grep "milestone issued (1)"
  bootstrapped=$?

  if [ $bootstrapped -eq 0 ]; then
    echo "Coordinator bootstrapped!"
    docker kill -s SIGINT $(cat ./coo.bootstrap.container)
    echo "Waiting coordinator bootstrap to stop gracefully..."
    sleep 10
    docker rm $(cat ./coo.bootstrap.container)
    rm ./coo.bootstrap.container
  else
    echo "Error. Coordinator has not been boostrapped."
    clean
    exit 127
  fi  
}

# Generates the P2P identities of the Nodes
generateP2PIdentities () {
  generateP2PIdentity node1 node1.identity.txt
  generateP2PIdentity node2 node2.identity.txt
  generateP2PIdentity coo coo.identity.txt
  generateP2PIdentity spammer1 spammer1.identity.txt
  generateP2PIdentity spammer2 spammer2.identity.txt

  # Identity of the autopeering node
  generateP2PIdentity node-autopeering node-autopeering.identity.txt
}

###
### Sets up the identities of the different nodes
###
setupIdentities () {
  generateP2PIdentities
}

# Sets up the identity of the peers
setupPeerIdentity9Args () {
  local peerName1="$1"
  local peerID1="$2"

  local peerName2="$3"
  local peerID2="$4"

  local peerName3="$5"
  local peerID3="$6"

  local peerName4="$7"
  local peerID4="$8"

  local peer_conf_file="$9"

  cat <<EOF > "$peer_conf_file"
  {
    "peers": [
      {
        "alias": "$peerName1",
        "multiAddress": "/dns/$peerName1/tcp/15600/p2p/$peerID1"
      },
      {
        "alias": "$peerName2",
        "multiAddress": "/dns/$peerName2/tcp/15600/p2p/$peerID2"
      },
      {
        "alias": "$peerName3",
        "multiAddress": "/dns/$peerName3/tcp/15600/p2p/$peerID3"
      },
      {
        "alias": "$peerName4",
        "multiAddress": "/dns/$peerName4/tcp/15600/p2p/$peerID4"
      }
    ]
  } 
EOF

}

setupPeerIdentity7Args () {
  local peerName1="$1"
  local peerID1="$2"

  local peerName2="$3"
  local peerID2="$4"

  local peerName3="$5"
  local peerID3="$6"

  local peer_conf_file="$7"

  cat <<EOF > "$peer_conf_file"
  {
    "peers": [
      {
        "alias": "$peerName1",
        "multiAddress": "/dns/$peerName1/tcp/15600/p2p/$peerID1"
      },
      {
        "alias": "$peerName2",
        "multiAddress": "/dns/$peerName2/tcp/15600/p2p/$peerID2"
      },
      {
        "alias": "$peerName3",
        "multiAddress": "/dns/$peerName3/tcp/15600/p2p/$peerID3"
      }
    ]
  } 
EOF

}

setupPeerIdentity5Args () {
  local peerName1="$1"
  local peerID1="$2"

  local peerName2="$3"
  local peerID2="$4"

  local peer_conf_file="$5"

  cat <<EOF > "$peer_conf_file"
  {
    "peers": [
      {
        "alias": "$peerName1",
        "multiAddress": "/dns/$peerName1/tcp/15600/p2p/$peerID1"
      },
      {
        "alias": "$peerName2",
        "multiAddress": "/dns/$peerName2/tcp/15600/p2p/$peerID2"
      }
    ]
  } 
EOF

}

setupPeerIdentity3Args () {
  local peerName1="$1"
  local peerID1="$2"

  local peer_conf_file="$3"

  cat <<EOF > "$peer_conf_file"
  {
    "peers": [
      {
        "alias": "$peerName1",
        "multiAddress": "/dns/$peerName1/tcp/15600/p2p/$peerID1"
      }
    ]
  } 
EOF

}

### 
### Sets the peering configuration
### 
setupPeering () {
  local node1_peerID=$(getPeerID node1.identity.txt)
  local node2_peerID=$(getPeerID node2.identity.txt)
  local coo_peerID=$(getPeerID coo.identity.txt)
  local spammer1_peerID=$(getPeerID spammer1.identity.txt)
  local spammer2_peerID=$(getPeerID spammer2.identity.txt)

  setupPeerIdentity5Args "node1" "$node1_peerID"  "spammer1" "$spammer1_peerID" config/peering-coo.json

  setupPeerIdentity5Args "node1" "$node1_peerID" "coo" "$coo_peerID" config/peering-spammer1.json
  setupPeerIdentity3Args "node2" "$node2_peerID" config/peering-spammer2.json
  setupPeerIdentity7Args "coo" "$coo_peerID" "spammer1" "$spammer1_peerID" "node2" "$node2_peerID" config/peering-node1.json
  setupPeerIdentity5Args  "spammer2" "$spammer2_peerID" "node1" "$node1_peerID" config/peering-node2.json

  # We need this so that the peering can be properly updated
  if ! [[ "$OSTYPE" == "darwin"* ]]; then
    sudo chown 65532:65532 config/peering-node1.json
    sudo chown 65532:65532 config/peering-node2.json
    sudo chown 65532:65532 config/peering-spammer1.json
    sudo chown 65532:65532 config/peering-spammer2.json
  fi
}

###
### Sets the autopeering configuration
### 
setupAutopeering () {
  local entry_peerID=$(getAutopeeringID node-autopeering.identity.txt)
  local multiaddr="\/dns\/node-autopeering\/udp\/14626\/autopeering\/$entry_peerID"

  # setEntryNode $multiaddr config/config-node1.json
  # setEntryNode $multiaddr config/config-spammer1.json
  # setEntryNode $multiaddr config/config-node2.json
  # setEntryNode $multiaddr config/config-spammer2.json
}

startAutopeering () {
  # Run the autopeering entry node
  echo "Starting autopeering entry node ..."
  docker-compose --log-level ERROR up -d node-autopeering
  sleep 5
}

stopContainers () {
  echo "Stopping containers..."
	docker-compose --log-level ERROR down -v --remove-orphans
}

startTangle () {
  if ! [ -f ./snapshots/private-tangle/full_snapshot.bin ]; then
    echo "Install your Private Tangle first with './private-tangle.sh install'"
    exit 128 
  fi

  startAutopeering

  export COO_PRV_KEYS="$(getPrivateKey coo-milestones-key-pair.txt)"
  startContainers
}

case "${command}" in
	"help")
    help
    ;;
	"install")
    installTangle
    ;;
  "start")
    startTangle
    ;;
  "update")
    updateTangle
    ;;
  "stop")
		stopContainers
		;;
  *)
		echo "Command not Found."
		help
		exit 127;
		;;
esac
