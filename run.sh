source .env

forge build

# forge script --chain $MAINNET_L2_CHAIN_ID script/CTFFactory.s.sol:CTFFactoryScript --rpc-url $MAINNET_RPC_URL --verify --etherscan-api-key $ETHERSCANKEY  --broadcast
# forge script --chain $LOCAL_HOST_CHAIN_ID script/CTFFactory.s.sol:CTFFactoryScript --rpc-url $LOCAL_HOST_RPC_URL --broadcast