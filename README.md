# Reach [![CircleCI Build Status](https://circleci.com/gh/reach-sh/reach-lang.svg?style=shield)](https://circleci.com/gh/reach-sh/reach-lang) [![GitHub License](https://img.shields.io/github/license/reach-sh/reach-lang)](https://raw.githubusercontent.com/reach-sh/reach-lang/master/LICENSE) [![Discord](https://img.shields.io/discord/628402598663290882)](https://discord.com/channels/628402598663290882) [![Docs](https://img.shields.io/badge/docs-delicious-blue)](https://reach-sh.github.io/reach-lang/index.html) [![Twitter Follow](https://img.shields.io/twitter/follow/reachlang?style=social)](https://twitter.com/reachlang) [![Subreddit subscribers](https://img.shields.io/reddit/subreddit-subscribers/reach_sh?style=social)](https://www.reddit.com/r/reach_sh)

We are building the next generation blockchain development platform that will completely transform the paradigm of decentralized application (DApp) development. DApps have enormous potential, but are impractical today because of barriers that have kept blockchain development risky and limited to specialists, like cryptographers. The Reach platform is a comprehensive environment that enables junior developers to build useful and safe DApps without years of experience and easily deploy them on a variety of different blockchain networks.

This repository is for the Reach language, the domain-specific language for trustworthy DApps used by the Reach platform.

Read the
[documentation](https://reach-sh.github.io/reach-lang/index.html) on GitHub. 

# Development

If you want to work on the Reach compiler, you'll need:
- stack v2.1.3
- z3 v4.8.5
- solidity v0.5.11
- algorand with application TEAL support

Installation on macOS:
```
$ brew tap ethereum/ethereum
$ brew install haskell-stack z3
$ brew install https://raw.githubusercontent.com/ethereum/homebrew-ethereum/7fa7027f20cca27f76c679d0c5b35ee3c565f284/solidity.rb
```

Installation on Ubuntu:
```
$ sudo apt update
$ sudo apt install z3
$ sudo snap install solc
$ curl -sSL https://get.haskellstack.org/ | sh
```

The source code is in the `hs` directory.
