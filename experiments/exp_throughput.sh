#! /bin/bash
set -eu

function ifExit(){
	ecode=$?
	if [[ "$ecode" != "0" ]]; then
		echo "$ecode : $1"
		exit 1
	fi
}

DATACENTERS=$1 # single or multi
N=$2 # number of nodes
BLOCKSIZE=$3 # block size (n txs)
TXSIZE=$4 # tx size
N_TXS=$5 # number of transactions per validator
MACH_PREFIX=$6 # machine name prefix
RESULTS=$7

set +u
export CLOUD_PROVIDER=$8 # defaults to amazonec2 in utils/launch.sh
set -u

echo "####################################" 
echo "Experiment!"
echo "Nodes: $N"
echo "Block size: $BLOCKSIZE"
echo "Tx size: $TXSIZE"
echo "Machine prefix: $MACH_PREFIX"
echo ""

echo "TMIMAGE $TM_IMAGE"
echo "TMHEAD $TMHEAD"

NODE_DIRS=${MACH_PREFIX}_data
bash experiments/launch.sh $DATACENTERS $N $MACH_PREFIX $NODE_DIRS

# deactivate mempools
for i in `seq 1 $N`; do
	curl -s $(docker-machine ip ${MACH_PREFIX}$i):46657/unsafe_set_config?type=\"int\"\&key=\"block_size\"\&value=\"0\" > /dev/null &
done

# start the tx player on each node
go run utils/transact_concurrent.go $MACH_PREFIX $N $N_TXS

export GO15VENDOREXPERIMENT=0 
#go run utils/transact.go $N_TXS $MACH_PREFIX $N
#ifExit "failed to send transactions"

# TODO: ensure they're all at some height (?)

#export NET_TEST_PROF=/data/tendermint/core
set +u
if [[ "$NET_TEST_PROF" != "" ]]; then
	# start cpu profilers and snap a heap profile
	for i in `seq 1 $N`; do
		curl -s $(docker-machine ip ${MACH_PREFIX}$i):46657/unsafe_start_cpu_profiler?filename=\"$NET_TEST_PROF/cpu.prof\"
		curl -s $(docker-machine ip ${MACH_PREFIX}$i):46657/unsafe_write_heap_profile?filename=\"$NET_TEST_PROF/mem_start.prof\"
	done
fi
set -u


echo "Wait for transactions to load"
done_cum=0
for t in `seq 1 100`; do
	for i in `seq 1 $N`; do
		n=`curl -s $(docker-machine ip ${MACH_PREFIX}$i):46657/num_unconfirmed_txs | jq .result[1].n_txs`
		if [[ "$n" -ge "$N_TXS" ]]; then
			done_cum=$((done_cum+1))
		else
			echo "val $i only has $n txs in mempool"
		fi
	done
	if [[ "$done_cum" -ge "$N" ]]; then
		break
	else
		echo "still waiting $t. got $done_cum, need $N"
	fi
	sleep 1
done
if [[ "$done_cum" -lt "$N" ]]; then
	echo "transactions took too long to load!"
	exit 1
fi
echo "All transactions loaded. Waiting for a block."

# wait for a block
while true; do
	blockheightStart=`curl -s $(docker-machine ip ${MACH_PREFIX}1):46657/status | jq .result[1].latest_block_height`
	if [[ "$blockheightStart" != "0" ]]; then
		echo "Block height $blockheightStart"
		break
	fi
	sleep 1
done

# wait a few seconds for all vals to sync
echo "Wait a few seconds to let validators sync"
sleep 2


# activate mempools
for i in `seq 1 $N`; do
	curl -s $(docker-machine ip ${MACH_PREFIX}$i):46657/unsafe_set_config?type=\"int\"\&key=\"block_size\"\&value=\"$BLOCKSIZE\"  &
done

set +u
if [[ "$CRASH_FAILURES" != "" ]]; then
	# start a process that kills and restarts a random node every second
	go run utils/crasher.go $MACH_PREFIX $N bench_app_tmcore &
	CRASHER_PROC=$!
fi
set -u

# massage the config file
echo "{}" > mon.json
netmon chains-and-vals chain mon.json $NODE_DIRS

# start the netmon in bench mode 
mkdir -p $RESULTS
if [[ "$N" == "2" ]]; then
	TOTAL_TXS=$(($N_TXS*2))	
else
	TOTAL_TXS=$(($N_TXS*4)) # N_TXS should be blocksize*4. So tests should run for 16 blocks
fi
netmon bench --n_txs=$TOTAL_TXS mon.json $RESULTS 


set +u
if [[ "$NET_TEST_PROF" != "" ]]; then
	# stop cpu profilers and snap a heap profile
	for i in `seq 1 $N`; do
		curl -s $(docker-machine ip ${MACH_PREFIX}$i):46657/unsafe_stop_cpu_profiler
		curl -s $(docker-machine ip ${MACH_PREFIX}$i):46657/unsafe_write_heap_profile?filename=\"$NET_TEST_PROF/mem_end.prof\"
	done
fi
set -u

