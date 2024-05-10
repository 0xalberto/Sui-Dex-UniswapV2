# testnet
PACKAGE_ID=0x95dfc0b0dc37856b22bab8436efa2b9b3de2f2bd9d1f32de3700494b378a491f

FACTORY=0x06991246809b0ed2f86ebe57be905d79983516ea3e21b07b295312bf36f8421e
# A
KYRINCODE_FAUCET_COIN_TYPE=0x082611c2c7c648ff229a5e76f1a7370ea6b6cb4039eb22686576eb45626fe54d::kyrincode_faucet_coin::KYRINCODE_FAUCET_COIN
# B
KYRINCODE_COIN_TYPE=0x78738d78352565548776fbd8ca71ab21c5c71773ce1c15738930f7887072feea::kyrincode_coin::KYRINCODE_COIN

# # create pool
# # balance: 100000000
# KYRINCODE_FAUCET_COIN=0x79a720fc38051f76e47e3faa4ad0048d38a8810734ebd4055e7cc2904f68b5e3
# # balance: 100000000
# KYRINCODE_COIN=0x19c46cebbf04f3ec3cf7eda9759578c6329b1bff7abbf7e1acd9ab71669f6d46
# sui client call --package $PACKAGE_ID \
#                 --module uniswapV2 \
#                 --function create_pool_with_coins_and_transfer_lp_to_sender \
#                 --type-args $KYRINCODE_FAUCET_COIN_TYPE $KYRINCODE_COIN_TYPE \
#                 --args $FACTORY $KYRINCODE_FAUCET_COIN $KYRINCODE_COIN \
#                 --gas-budget 100000000

# swap kyrincode_coin for kyrincode_faucet_coin
POOL=0x0afc17d63ec799d5b1ad1d6be37ac86c8f4d12a16334b0ea6688d77fe22a0c82
# balance: 100000000
KYRINCODE_COIN=0x67af79f8f414a1c965f6174dd987ddf3333d1aec04598a7b90c527c337d47ceb
MIN_OUT=0
sui client call --package $PACKAGE_ID \
                --module uniswapV2 \
                --function swap_b_for_a_with_coin_and_transfer_to_sender \
                --type-args $KYRINCODE_FAUCET_COIN_TYPE $KYRINCODE_COIN_TYPE \
                --args $POOL $KYRINCODE_COIN $MIN_OUT \
                --gas-budget 100000000