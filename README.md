# Universal uniswap-v3-staker

This is the universal staking contract designed for [Uniswap V3](https://github.com/Uniswap/uniswap-v3-core) that accepts arbitrary reward function.

## Security audit is TBD.

- **This is still under development and not yet ready for production.** This section will be updated with relevant addresses once it's ready and live.

## Links:

- [Contract Design](paper/universal_v3_staking.pdf)

## Development and Testing

```sh
$ yarn
$ yarn test
```

## Gas Snapshots

```sh
# if gas snapshots need to be updated
$ UPDATE_SNAPSHOT=1 yarn test
```

## Contract Sizing

```sh
$ yarn size-contracts
```
