# ƒlaunch Protocol - README
## Overview
The ƒlaunch protocol is an innovative platform designed to revolutionize the way memecoins are launched and traded. With a focus on creating sustainable "meme economies," the ƒlaunch protocol introduces features that ensure a fair, transparent, and risk-free launch environment for all participants, from developers to traders. By integrating mechanisms like Progressive Bid Walls and decentralized revenue-sharing models, ƒlaunch aligns the incentives of all stakeholders towards long-term success rather than short-term gains.

## Key Features
1. **Buyback and Bid Wall**:
   - Trading fees are allocated towards buybacks through Progressive Bid Walls, which start just below the current spot price and adjust upward as the price increases. This mechanism helps stabilize the coin's value and ensures continuous market activity.

2. **Meme Economies**:
   - Coin holders have the power to halt Progressive Bid Walls and instead accumulate revenue in a treasury. This treasury can be utilized in ways determined by the token holders, fostering a community-driven economy.

3. **Devs Get Revs**:
   - Developers, known as "flaunchers," receive a percentage of all trading fees. This aligns their incentives with the long-term health of the memecoin, encouraging them to focus on sustainable growth rather than quick pumps and dumps. Dev Revs are always converted to our ETH equivalent token (flETH) using our Internal Swap Pool. This means no negative token dumps to get fees.

4. **Risk-Free Fair Launch**:
   - During the initial fair launch period, all ETH proceeds are funneled back into a Progressive Bid Wall. This allows early buyers to exit at their entry price (minus the AMM fee), ensuring that no party has an unfair advantage, and guaranteeing a fair launch for all participants.

## Why ƒlaunch?
Memecoin launchpads have traditionally been extractive, often benefitting Key Opinion Leaders (KOLs), MEV operators, and even validators at the expense of the broader community. The ƒlaunch protocol seeks to disrupt this model by creating an environment where launching a coin is not only fun and fair but also gives users a better chance of profit. By enabling the formation of true "meme economies" and rewarding developers through revenue sharing, ƒlaunch offers a fresh, degen-centric approach to memecoin launches.

## Getting Started
To start using the ƒlaunch protocol, please refer to our [documentation](https://docs.flaunch.gg/flaunch-docs) which provides detailed instructions on setting up, launching, and managing your memecoin within the ƒlaunch ecosystem.

For further assistance, feel free to reach out to our team through our official communication channels.

## Contracts
### Flaunch Addresses — current generation (v1.3.x / v1.4.x paired-token hooks, multi-asset managers)

One contract generation, live on five chains. Base is release v1.3.1 (2026-08-20, multi-asset
managers 2026-08-25); Robinhood Chain and Base Sepolia are the v1.3.3 hook regeneration
(2026-09-03) on the same source; Ethereum is v1.4.0 (2026-09-11, native ETH default pairing, no
flETH) and Arbitrum One is v1.4.1 (2026-09-14), the same paired-token ABI family. `PoolSwap` is the
protected router of v1.3.4 (2026-09-08). Hooks are CREATE3 deploys, so Robinhood and Base Sepolia
share hook addresses; every other contract in this table is chain-specific. The canonical
machine-readable source is [`@flaunch/sdk`](https://www.npmjs.com/package/@flaunch/sdk) ≥ 0.17.0
(`*V1_3Address` maps); this table is generated from it.

| Contract | Ethereum (1) | Arbitrum One (42161) | Base (8453) | Robinhood (4663) | Base Sepolia (84532) |
|---|---|---|---|---|---|
| PositionManager (hook) | `0xb741a710E456FC6d7f76c88F5C56B27D05e8A5DC` | `0xCAb62e007AB6656877Ab556cEa330De27AE025DC` | `0x588C683EcC450F8b2aAdb13D7f63792b840425DC` | `0x8D346f24278C5CD786309161aAC0fC2bbe4c25dc` | `0x8D346f24278C5CD786309161aAC0fC2bbe4c25dc` |
| AnyPositionManager (hook) | `0x0215C3ef94ef3e86c32e847c662ad649000965Dc` | `0xbbE1b9831117E829Fe80Be97fCe82F2b49C1a5DC` | `0x6eA0eDeE449A287504990Df8D87951B9436825Dc` | `0x9AbfbDc34A294De5210C0889f21D5Af54C4965DC` | `0x9AbfbDc34A294De5210C0889f21D5Af54C4965DC` |
| Flaunch (ERC721) | `0x393a09033Bf60cF67809d6D8b77C1254f39d2FF9` | `0x99c55BC5C2e4a15a98cBc705F240cF8b1889775f` | `0x475a09618BfD00FA4CB03B8504e95b62075E6F7D` | `0x373c037C90a681079c3343ddAFCEEa8d9D8DE96E` | `0xC17a8523290ea839B4C1DdeF121D8736A06F5623` |
| AnyFlaunch (ERC721) | `0x154f2E2ef6fAdFFe6bCF4d86a2639A6Ef4981c5C` | `0x71001DD43209015cdd430F2ea043c93AfcE43666` | `0x299c7E6992A4630D77A8cbd60AA78E17189E53F7` | `0x1bbbD15A6D5176edc7B42f2cc6cA800D9d74015D` | `0x2154c604df568A5285284D1c4918DC98C39240df` |
| BidWall | `0xE02e0C934969647E0099Cb231BBC6BBCe1b91dF6` | `0x36b41E8F726011D26Dc9812d2e8E76F490e9B590` | `0x0dae90B70f62CE3b1D5278F4763BD1f595d6A687` | `0xB95ad380B6C2F39b67d8582Eb198ba3881Aa06D4` | `0xDedFD72f5E0555BD21e3C3d94297dEe2a435b366` |
| AnyBidWall | `0xE1eBcD62AEBd327A4c22dB9e68A8E81119a7eABF` | `0xd9e3c35ea96C1108a574050BD1Be940b1622A147` | `0x9D58CA8011096aD711baBF0d990c45b9D5bB047D` | `0xf32316145caf0A381FA587A7CE1bf850d58Af3aC` | `0x4c8A5C0Fe00448c5BBbd0D7AEc95C9eF3b81262b` |
| FlaunchZap (factory-bound) | `0x11666704fcd96e1CAFF9b99501FA1e79D64900fC` | `0xBd5ae825DDC67834002A6b586CfF5802971e3A7F` | `0xf787d757674b21efD713fB636B16ed994bfa82A8` | `0x740f8278Fd9C548fF50b64805337eA8Ad24b2553` | `0x0c560537301396683C150EaDe42277a04b96e6d8` |
| PoolSwap (protected router) | `0x05c6C717B2a985809a83D27F779044c2da27fd56` | `0x206cD26d8567Ea76Ffa719995251a3878073Fb8A` | `0x1B8065a099AdcD7aa7c5e241e3596B56ec98bA5a` | `0xD33dD3B3Aea607F2cC38cdd154eF5d48847Aa764` | `0xB32a99502f433f78454a4D20304E654CDda75c5c` |
| PairedTokenRegistry | `0xFc28B339376018727eFcD45fdb257D0A0861A391` | `0x16EF4F8e1d41cE4727d98ae0E9EC4e9cDDd14Ac4` | `0x26958422636655b5a4eCE23a062e2EB61332c6da` | `0xC3F4E72DE4D37988F12C101b0766Fd8462F6Faf9` | `0x23cb441d18CA75c6a14964B06806dF668d45A1C6` |
| FeeEscrow (multi-token) | `0xd992F465d55B005E8D2Aff9fcE977Cb78f5652e0` | `0x635B4afCf977ed946BDa31fc7E381c970159077a` | `0x17fbF54d6D15EbFF82EEe77E616F701952D08Bb4` | `0x4Fb9dE6bbe970A49C19fB967F937351728C01b8f` | `0xF4AF7b459E971d9757C2100c626199C6C6334FCa` |
| ReferralEscrow | `0x2FAde59484677FE39144D6d1B74aE57E8E424595` | `0x9972EFc88674bbeeB1B0f0116A73a3006a98Ba3c` | `0xE86BFeBC4F094D36074833618779D279a9Af01Aa` | `0xB9827C0c7Cb61be4D58700B114E34D8448889eD8` | `0x7C6088C1185FbB770deB1CA7DdeeD4ba57659663` |
| TokenImporter | `0x319A17b4D6529107FC9a8312371f3C74D4083e5e` | `0x083a628477048CB37831A4A7D8Ebff1A0659af3f` | `0xEa78C26690b5a0ddE2A5a8db7760B5dA79bfd76e` | `0xf7579C3cb8607F6CE00311465d28Ac45666f39Ad` | `0xc65fC67Fa953869dF97ab2DBa96fA58F2bDC9891` |
| TreasuryManagerFactory | `0xD2B91d92AF59b7BEd15b5458feCF0e87C8A7c21e` | `0x15617e43Ba6E4f51cE2A54d30Af26E744190e313` | `0xB03Be6c735ef90189D6a22bBC8F6A45a33348fDe` | `0xE1eBcD62AEBd327A4c22dB9e68A8E81119a7eABF` | `0x98dfdd0AAc46c85FA35d67941d394019b7e3a18d` |
| RevenueManager (implementation) | `0xf2947840eeA730f9E9ECC6559526392d68e89569` | `0x32e59c950DBBf0123E3A7008DaB56480c3500983` | `0x908D692E628073A5B644Bc32B8dF57A5d1842288` | `0xFc28B339376018727eFcD45fdb257D0A0861A391` | `0x0cf6BdF0a85A9d6763361037985B76C8893553Af` |
| AddressFeeSplitManager (implementation) | `0x740f8278Fd9C548fF50b64805337eA8Ad24b2553` | `0xB4512bf57d50fbcb64a3adF8b17a79b2A204C18C` | `0x7dC776cf57DacA91b315fe4F8803577dAb560ba5` | `0x7dc0f14204841e0314eB0265a0c420995F200243` | `0x7397390360Bd9D559D9277E60d47b99933791232` |
| DynamicAddressFeeSplitManager (implementation) | `0x0f03Aa8d303Ee15ed3Be81Bf43c41EFfFa4a7a5B` | `0xFE5a906379F78965393D23BC604036bb74214926` | `0xC4a0B79A0dB1F7F67da97E7F9A8867B6CaF017b2` | `0x1969bcF2779D53FeEA95480a7ab79f7cEfeE1681` | `0xD37aeE3eDebf59F149b5D3b29B6Ad2239F8A6B00` |
| ERC721OwnerFeeSplitManager (implementation) | `0x43ff2F15A821C24A0576Fc376B789846080F2F0f` | `0x8C31AC369f6e2807109d0C25F2c26dB6A666138e` | `0xDbFA9d3cab72EAE6Ba44ebC27175706aA451d9c0` | `0x51BdE7C1e2Ea54949C015F4f3ED3CAE185543C0b` | `0xcE84bdD578c60E98E79A3A05392010b443DdaA9e` |
| StakingManager (implementation) | `0xEf8be05d08fbCBFB89bAa05fA7a56BD818Ca9181` | `0xA56f12E2488E0Eb0EFC3468a39aefEFa9F28233a` | `0x72b9192017361eA00cDc1Cf1AC0F178cf89920cA` | `0xd992F465d55B005E8D2Aff9fcE977Cb78f5652e0` | `0x4D5616c04e59CE47b40e54c1D106363DA74c1a2E` |
| GroupMapper | `0x3F7C69F516238FEC37CF06Fde0B95BD37B2B531D` | `0xd0c557c72B2d381f7794599E4d39d906744FBc21` | `0x4a68638179De37163d86B10e6B4b927CA1a0dE87` | `0xBdbF379f9EdFB5993FC00b41AAEfeE8475eAC0Ac` | `0x41964Dd84F25Cd5830F5c4deEb54eFab3eD7E087` |
| FlaunchManagerZap | `0xf7579C3cb8607F6CE00311465d28Ac45666f39Ad` | `0xa55904b7a456859649766CF7f30264A90285df05` | `0xD7E0c1D2B2a588cEC3b2Bdc9428FfE59b739749B` | `0xAf037090FF86EFdc8d4ba82728aC93042ad1EC73` | `0xF175A370Eb26Ea26C42caAEcD10EE723ed844C50` |
| ClosedPermissions | `0x00BD5d089626F84E0DfF241D5e71336Add6D4bF3` | `0x8ea82B35B890987CD6B55271F593aBbC0Fe226f6` | `0x4dfc76A31A2a0110739611683a8b6C5201480fa1` | `0xF0469beF728c498f3621008C65B95EDa56C82Ae3` | `0x551aeD820CAfaca2f9cD1C637AAc076D05a03AC2` |
| WhitelistedPermissions | `0x4765Ea884Bc29219eCC430F2C478d4f646071d78` | `0x862D5471B3E49d48E2E152793f00c91a9CAf054A` | `0xaCE028CB08A19C4d2a6e442516EbA7d114C09Af9` | `0xF772256B811D2241488d3d659E9cf797B387eFC3` | `0xBe6245B2C8d59618A080BD5B2d67B3c813a9AB7c` |

Superseded hook generations still serve the coins launched on them (coins never migrate):
Robinhood `0x588C683E…` / `0x6eA0eDeE…` (v1.3.1, 2026-08-21 → v1.3.3) and Base Sepolia
`0x5558e727…` / `0x28118f40…` (`.vpt2`, 2026-08-06 → v1.3.3). Integrators resolving "which hook
is this coin on" should consult `SupersededPositionManagerV1_3Address` alongside the current maps.

### Flaunch Addresses — Game Mode: spend gate, vested launches and the developer fee split (v1.5.0)

A Game Mode coin launches through `AnyFlaunchZap` onto its own `AnyPositionManager` hook, may vest
part of its supply in `MemecoinVesting`, and routes swap fees through the chain's
`FeeCalculatorDispatcher` to a `SpendGatedSignerFeeCalculator`, which caps what each wallet can
spend to what a game's gate has signed for it. `GameDeveloperFeeSplitManager` pins the game
developer's 5% share of creator fees. On the four mainnets every contract below the calculators
is a CREATE3 parity deploy (2026-09-17 on Base, Robinhood and Arbitrum; 2026-09-21 on Ethereum), so
one address serves all of them. All are source-verified on the chain's explorer (Sourcify for
Robinhood). Each dispatcher and v1 calculator belongs to the hook generation in the table above.

| Contract | Ethereum (1) | Arbitrum One (42161) | Base (8453) | Robinhood (4663) | Base Sepolia (84532) |
|---|---|---|---|---|---|
| FeeCalculatorDispatcher | `0x99922f8E94E67AB29401F67eBa30163D1e9eb994` | `0xc5eE9697de8544Dc3f63A943A80Bd388Ac30968A` | `0xdbC2F399BbAC8CD766F20C9B917A9A6ECAD5bc4b` | `0x981b0F51667A250Af9DADB86056bf22914F53F27` | `0xd381f8Ea57DF43c57CFE6e5b19A0A4700396F28c` |
| SpendGatedSignerFeeCalculator v1 | `0x8eD725D61AA687951F430Dd6E76e3A0108436005` | `0x9Ef19e3033c23AEECEb96e4C28faCaa15098d0dA` | `0xD8E46A2CA31915D9B76cC8e6B365b7ed46B77b01` | `0x120A2E0F8f431136897Dc78c24B069146A65d79A` | `0x54Cdcf0BCbc3a33f470E07134C10582F93058a32` |
| SpendGatedSignerFeeCalculator v2 (cumulative ceilings) | `0x91938A66323725252043c03ad3066542Ac793057` | `0x91938A66323725252043c03ad3066542Ac793057` | `0x91938A66323725252043c03ad3066542Ac793057` | `0x91938A66323725252043c03ad3066542Ac793057` | `0x8a36826253882c8b505D6D78a71B780Ac9c98eA9` |
| AnyPositionManager (vested hook) | `0xE753a351FB498051a09Dc130fcC29aEBc76525DC` | `0xE753a351FB498051a09Dc130fcC29aEBc76525DC` | `0xE753a351FB498051a09Dc130fcC29aEBc76525DC` | `0xE753a351FB498051a09Dc130fcC29aEBc76525DC` | `0xE753a351FB498051a09Dc130fcC29aEBc76525DC` |
| AnyFlaunch (vested, ERC721) | `0xCC6C194fD1d2fbe5fCF2F228DfDF3892bfC76C9c` | `0xCC6C194fD1d2fbe5fCF2F228DfDF3892bfC76C9c` | `0xCC6C194fD1d2fbe5fCF2F228DfDF3892bfC76C9c` | `0xCC6C194fD1d2fbe5fCF2F228DfDF3892bfC76C9c` | `0xE9ec22D7c245743DC5dC958e5cCd664732Ae04b9` |
| AnyFlaunchZap | `0xDF22fe67b69916aEFf4846ecB45db0B9016092f6` | `0xDF22fe67b69916aEFf4846ecB45db0B9016092f6` | `0xDF22fe67b69916aEFf4846ecB45db0B9016092f6` | `0xDF22fe67b69916aEFf4846ecB45db0B9016092f6` | `0xaA0872BcA9c6eCB0Cda78528cd89149822bc124D` |
| MemecoinVesting | `0xfE616a9c723f5fB35728C7ccCb84dB034A18cC86` | `0xfE616a9c723f5fB35728C7ccCb84dB034A18cC86` | `0xfE616a9c723f5fB35728C7ccCb84dB034A18cC86` | `0xfE616a9c723f5fB35728C7ccCb84dB034A18cC86` | `0x3F8004335C113Fac0873c061a28670F0AaD6A87b` |
| GameDeveloperFeeSplitManager (implementation) | `0xd9E9a5cCdbdb8300B81b08979EA0acB0BC3B2F03` | `0xd9E9a5cCdbdb8300B81b08979EA0acB0BC3B2F03` | `0xd9E9a5cCdbdb8300B81b08979EA0acB0BC3B2F03` | `0xd9E9a5cCdbdb8300B81b08979EA0acB0BC3B2F03` | `0x905a278CaEA18768180e4Bb4A6BBA1FE1ddcEA6e` |

### Flaunch Addresses — legacy generations (pre-v1.3, Base and Base Sepolia)

| Contract              | Base                                         | Base Sepolia                                 |
|-----------------------|----------------------------------------------|----------------------------------------------|
| FeeExemptions         | `0xfdCE459071c74b732B2dEC579Afb38Ea552C4e06` | `0xD0aa3724074727629A9794d8A06CA1B2aDb51a85` |
| MarketCappedPrice     | `0xf318e170d10a1f0d9b57211e908a7f081123e7f6` | `0xe8f624a3fd5b3ae3914baac21f9fd636259f57f2` |
| PositionManager       | `0x23321f11a6d44fd1ab790044fdfde5758c902fdc` | `0x4e7cb1e6800a7b297b38bddcecaf9ca5b6616fdc` |
| BidWall               | `0x7f22353d1634223a802d1c1ea5308ddf5dd0ef9c` | `0x6f2fa01a05ff8b6efbfefd91a3b85aaf19265a00` |
| FairLaunch (Deprecated) | `[Deprecated]`                               | `[Deprecated]`                               |
| TreasuryActionManager | `0xfb5c20c4e60c9c64648dd3692437e3e313add4a4` | `0xc5299fb5c8ccad97fb74f9f346337d9e00c319ca` |
| Notifier              | `0x75a8264b748147fdbfAE518CF37Fd3A83FC03aB7` | `0xCc4B78FBACFD16b0beFd742b163185f9671d01A6` |
| Memecoin              | `0xF1EEeeeeECd95E9Eb2df58484ceed175AcBD945C` | `0x08D9f2512da858fB9DbEaFb62EE9F5F5a3519367` |
| MemecoinTreasury      | `0x7397390360bd9d559d9277e60d47b99933791232` | `0x89ac06abf75752c961f6b3b44b699ec03f5f123c` |
| Flaunch               | `0x516af52d0c629b5e378da4dc64ecb0744ce10109` | `0xe2ef58a54ee79dac0d4a130ea58b340124df9438` |
| StaticFeeCalculator   | `0xaA27191eB96F8C9F1f50519C53e6512228f2faB9` | `0x8FCedC6bf6bd2691CA9efd9E41Ff01ef325585e0` |
| BuyBackAction         | `0xDa4866c97E3414b920663041C680012D6Ee296bE` | `0xb480B22fE3a802526c2C2533535ddB8DA6694Aec` |
| BurnTokensAction      | `0x8696a1F26e678D15c251f07556696b877D3382c8` | `0xe8c3A9428aA97A8Cef5DF45af7d6Af7d553dd92c` |
| FlaunchPremineZap     | `0xeFA8267954b0740dC981a40D8E23d07116c8DfFE` | `0xb84d6cc0cC54A1a30dF07e4B869Cc4AFa7405281` |
| FlaunchZap            | `0xa9bd947751c6a6d33ccd0ef4a03c48466f24c172` | `0x25b747aeca2612b9804b5c3bb272a3daefdc6eaa` |
| ReferralEscrow        | `0xd381f8ea57df43c57cfe6e5b19a0a4700396f28c` | `0xd3d9047cabe3346c70b510435866565176e8ce12` |
| PoolSwap              | `0xdcf8e5e2a21e9b7e37b1b1a6612f1376723dd08e` | `0x9ef9762c55275b1ba8b6b900fa4c3a349f581014` |

### flETH Addresses
| Contract              | Base                                         | Base Sepolia                                 |
|-----------------------|----------------------------------------------|----------------------------------------------|
| flETH                 | `0x000000000d564d5be76f7f0d28fe52605afc7cf8` | `0x79FC52701cD4BE6f9Ba9aDC94c207DE37e3314eb` |
| flETH (Robinhood Chain, 4663; WETH-backed vault, `deposit(uint256) payable`) | `0x00000000043C1117DAFA3A3D0C7148Eb48B30130` | — |
| FlAaveV3WethGateway   | `0x344e4d19c851b317bb65d31bb5c4e3815b53d727` | `0xed5fEec571D132AeA6D6a636c683b818b3442888` |
| AaveV3Strategy        | `0xd93855bab40a80df2f8ccaae079f2b73d5ec8527` | `0xd5f7Fe1954C5c772Dd562CbcF1e26a6D75Bc0351` |
| flETHHooks            | `0x9e433f32bb5481a9ca7dff5b3af74a7ed041a888` | `0x4bd2ca15286c96e4e731337de8b375da6841e888` |

### Uniswap V4 Addresses

Robinhood Chain (4663): PoolManager `0x8366a39CC670B4001A1121B8F6A443A643e40951`, PositionManager `0x58daec3116aae6D93017bAAea7749052E8a04fA7`, Quoter `0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94`, StateView `0xF3334192D15450CdD385c8B70e03f9A6bD9E673b`, UniversalRouter `0x8876789976dEcBfCbBbe364623C63652db8C0904`, Permit2 `0x000000000022D473030F116dDEE9F6B43aC78BA3`.
| Contract              | Base                                         | Base Sepolia                                 |
|-----------------------|----------------------------------------------|----------------------------------------------|
| PoolManager           | `0x498581fF718922c3f8e6A244956aF099B2652b2b` | `0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408` |
| PositionDescriptor    | `0x176690c5819A05123b3cD80bd4AA2846cD347489` | `0x33E61BCa1cDa979E349Bf14840BD178Cc7d0F55D` |
| ProxyAdmin            | `0x9B95aF8b4C29346722235D74Da8Fc5E9E3232Eb3` | `[Unknown]`                                  |
| PositionManager       | `0x7C5f5A4bBd8fD63184577525326123B519429bDc` | `0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80` |
| Quoter                | `0x0d5e0F971ED27FBfF6c2837bf31316121532048D` | `0x4A6513c898fe1B2d0E78d3b0e0A4a151589B1cBa` |
| StateView             | `0xA3c0c9b65baD0b08107Aa264b0f3dB444b867A71` | `0x571291b572ed32ce6751a2Cb2486EbEe8DEfB9B4` |
| UniversalRouter       | `0x6fF5693b99212Da76ad316178A184AB56D299b43` | `0x492E6456D9528771018DeB9E87ef7750EF184104` |

## Project Setup
We use [Foundry](https://book.getfoundry.sh/) for tests and deployment. Refer to installation instructions for foundry [here](https://github.com/foundry-rs/foundry#installation).

```sh
git clone https://github.com/flayerlabs/flaunchgg-contracts.git
cd flaunchgg-contracts
forge install
```

Copy `.env.sample` into `.env` and fill out the env variables.

### Tests

```sh
forge test
```

---

This README serves as a high-level introduction to the ƒlaunch protocol. For more technical details, refer to the linked documentation and resources.
