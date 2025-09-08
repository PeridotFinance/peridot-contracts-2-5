Contracts Structure

- core: Core lending and protocol contracts (tokens, controller, models, oracles).
- cross-chain: Hub/Spoke and cross-chain pTokens used with Axelar flows.
- xperidot: xPeridot vault, staking, and tier rewards.

Notes
- Paths were reorganized to improve clarity without changing logic.
- Only cross-chain and xPeridot files were moved to avoid invasive refactors. Core files remain in place for now.
- Imports in scripts/tests were updated accordingly.

