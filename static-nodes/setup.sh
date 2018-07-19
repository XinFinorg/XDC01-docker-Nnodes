#!/bin/bash

#
# Create all the necessary scripts, keys, configurations etc. to run
# a cluster of Quorum nodes with IBFT consensus.
#
# Run the cluster with "docker-compose up -d"
#
# Geth and Constellation logfiles for Node N will be in qdata_N/logs/
#

#### Configuration options #############################################

RPC_PORT=22000
GETH_PORT=21000
CONSTELLATION_PORT=9000

function isPortInUse {
        if nc -zv -w30 $1 $2 <<< '' &> /dev/null
        then
                return 1
        else
                return 0
        fi
}

read -p "Please enter no. of inital VALIDATOR nodes you wish to setup: " num_validator_nodes
read -p "Please enter no. of inital REGULAR nodes you wish to setup : " num_regular_nodes
read -p "Please enter public IP of this host machine : " public_ip

# One Docker container will be configured for each IP address in this subnet
read -p "Please enter a unique subnet to use for local docker n/w (e.g. 172.13.0.0/16) : " docker_subnet

# Docker image name
image=xinfinorg/quorum:istanbul-tools

	until $(isPortInUse 'localhost' $((1+GETH_PORT+OFFSET)))
	do
		if ! $(isPortInUse 'localhost' $((1+GETH_PORT+OFFSET))); then
        		echo "Port is in use so auto incrementing"
        		echo $((1+GETH_PORT+4000))
			OFFSET=$OFFSET+4000
			echo $OFFSET
		else
        		echo "Port is free so using default port"
        		echo $((1+GETH_PORT))
			OFFSET=0
			echo $OFFSET
		fi

done

########################################################################

./cleanup.sh

uid=`id -u`
gid=`id -g`
pwd=`pwd`

nnodes=$(($num_validator_nodes+$num_regular_nodes))

#### Create directories for each node's configuration ##################

echo '[1] Configuring for '$nnodes' nodes.'

for n in $(seq 1 $nnodes)
do
    qd=qdata_$n
    mkdir -p $qd/{logs,keys}
    mkdir -p $qd/dd/geth
done

echo '[2] Creating keys for validator nodes'

# Use istanbul-tools for generating validator nodekeys, genesis/extradata
docker run -u $uid:$gid -v $pwd/ibft:/qdata $image /bin/bash -c "cd qdata/ && /usr/local/bin/istanbul setup --num $num_validator_nodes --verbose --nodes --quorum --save"

#### Make static-nodes.json and store keys #############################

echo '[3] Creating static-nodes.json.'

echo "[" > static-nodes.json
for n in $(seq 1 $nnodes)
do
    qd=qdata_$n
    v=$((n-1))

    if [[ $n -le $num_validator_nodes ]]
    then
	    cp ibft/$v/nodekey $qd/dd/nodekey
    else
	# Generate the regular node's Enode and key
    	docker run -u $uid:$gid -v $pwd/$qd:/qdata $image /usr/local/bin/bootnode -genkey /qdata/dd/nodekey
    fi

    enode=`docker run -u $uid:$gid -v $pwd/$qd:/qdata $image /usr/local/bin/bootnode --nodekey /qdata/dd/nodekey -writeaddress`

    # Add the enode to static-nodes.json
    sep=`[[ $n < $nnodes ]] && echo ","`

    echo '"enode://'$enode'@'$public_ip':'$((n+21000+OFFSET))'?discport=0"'$sep >> static-nodes.json

done
echo "]" >> static-nodes.json







# generate the allocated accounts section to be used in both Raft and IBFT
for i in $(seq 1 $nnodes)
do
    qd=qdata_$i

    # Generate an Ether account for the node
    touch $qd/passwords.txt
    create_account="docker run -u $uid:$gid -v $pwd/$qd:/qdata $image /usr/local/bin/geth --datadir=/qdata --keystore=/qdata/dd/keystore --password /qdata/passwords.txt account new"
    account1=`$create_account | cut -c 11-50`
    echo "Accounts for node $i: $account1"

    # Add the account to the genesis block so it has some Ether at start-up
    sep=`[[ $i < $nnodes ]] && echo ","`
    cat >> alloc.json <<EOF
    "${account1}": { "balance": "1000000000000000000000000000" }${sep}
EOF
done


ALLOC=`cat alloc.json`
cat ibft/genesis.json | jq ". | .alloc = {$ALLOC}" > genesis.json




#### Create accounts, keys and genesis.json file #######################

echo '[4] Copying genesis.json'

for n in $(seq 1 $nnodes)
do
    qd=qdata_$n
    # Generate passwords.txt for unlocking accounts, To-Do Accept user-input for password
    # touch $qd/passwords.txt
    cp genesis.json $qd/genesis.json
    mkdir -p $qd/dd/keystore
    cp ../keys/key.json $qd/dd/keystore/key
done

#### Make node list for tm.conf ########################################

nodelist=()
for n in $(seq 1 $nnodes)
do
    sep=`[[ $n != 1 ]] && echo ","`
    nodelist=${nodelist}${sep}'"http://'${public_ip}':'$((n+9000+OFFSET))'/"'
done

#### Complete each node's configuration ################################

echo '[5] Creating Quorum keys and finishing configuration.'

for n in $(seq 1 $nnodes)
do
    qd=qdata_$n

    cat templates/tm.conf \
        | sed s/_NODEIP_/$public_ip/g \
        | sed s%_NODELIST_%$nodelist%g \
        | sed s/_NODEPORT_/$((n+9000+OFFSET))/g \
              > $qd/tm.conf

    cp static-nodes.json $qd/dd/static-nodes.json

    # Generate Quorum-related keys (used by Constellation)
    docker run -u $uid:$gid -v $pwd/$qd:/qdata $image /usr/local/bin/constellation-node --generatekeys=qdata/keys/tm < /dev/null > /dev/null
    echo 'Node '$n' public key: '`cat $qd/keys/tm.pub`

    if [[ $n -le $num_validator_nodes ]]
    then
         cat templates/start-node.sh \
       	    | sed s/_PORT_/$((n+21000+OFFSET))/g \
            | sed s/_RPCPORT_/$((n+22000+OFFSET))/g \
            | sed s/_MINE_/"--mine"/g \
              > $qd/start-node.sh
    else
	  cat templates/start-node.sh \
            | sed s/_PORT_/$((n+21000+OFFSET))/g \
            | sed s/_RPCPORT_/$((n+22000+OFFSET))/g \
            | sed s/_MINE_/""/g \
              > $qd/start-node.sh
    fi
    chmod 755 $qd/start-node.sh

done
rm -rf ibft/*
rm -rf static-nodes.json
rm -rf alloc.json

#### Create the docker-compose file ####################################

cat > docker-compose.yml <<EOF
version: '2'
services:
EOF

for n in $(seq 1 $nnodes)
do
    qd=qdata_$n

    cat >> docker-compose.yml <<EOF
  node_$n:
    image: $image
    restart: always
    volumes:
      - './$qd:/qdata'
    networks:
      - xdc_network
    ports:
      - $((n+21000+OFFSET)):$((n+21000+OFFSET))
      - $((n+22000+OFFSET)):$((n+22000+OFFSET))
      - $((n+23000+OFFSET)):$((n+23000+OFFSET))
      - $((n+9000+OFFSET)):$((n+9000+OFFSET))
    user: '$uid:$gid'
EOF

done

cat >> docker-compose.yml <<EOF

networks:
  xdc_network:
    driver: bridge
    ipam:
      driver: default
      config:
      - subnet: $docker_subnet
EOF

echo '[5] Removing temporary containers.'
# Remove temporary containers created for keys & enode addresses - Note this will remove ALL stopped containers
docker container prune -f > /dev/null 2>&1
