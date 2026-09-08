# Changelog

## [2.0.1](https://github.com/bitwise-media-group/github-settings/compare/v2.0.0...v2.0.1) (2026-09-08)


### Bug Fixes

* **deps:** update bitwise-media-group/github-workflows action to v6.2.0 ([#29](https://github.com/bitwise-media-group/github-settings/issues/29)) ([b2f0f29](https://github.com/bitwise-media-group/github-settings/commit/b2f0f2953fa35a9d188c9ae5ee9bd4522d95f160))
* **deps:** update bitwise-media-group/github-workflows action to v6.3.0 ([#32](https://github.com/bitwise-media-group/github-settings/issues/32)) ([35faa27](https://github.com/bitwise-media-group/github-settings/commit/35faa273b2ffe7dadc34927972d4a8146f381ab1))

## [2.0.0](https://github.com/bitwise-media-group/github-settings/compare/v1.2.0...v2.0.0) (2026-08-15)


### ⚠ BREAKING CHANGES

* **labels:** labels-sync / import now delete dependabot's ecosystem labels (javascript, python, go, ...) from repos when absent from labels.json instead of keeping them.

### Features

* allow the make repo 'release' vanity branch ([23348cf](https://github.com/bitwise-media-group/github-settings/commit/23348cfb293ce54ae464228f2e2ff01578227209))
* **labels:** never delete dependabot per-ecosystem labels ([e97ba20](https://github.com/bitwise-media-group/github-settings/commit/e97ba2022843feee427ce69b34f914d8f1b2ecab))
* **labels:** rebuild label set around renovate ecosystems ([43219bb](https://github.com/bitwise-media-group/github-settings/commit/43219bb39a5105b0dfd3a426103ec12e4f8a27b3))
* **labels:** stop preserving dependabot ecosystem labels ([b99cbef](https://github.com/bitwise-media-group/github-settings/commit/b99cbef4440eabcb294a084830852073577a1fad))
* **org-config:** add the Renovate App to the pull-request ruleset bypass ([1ed5ced](https://github.com/bitwise-media-group/github-settings/commit/1ed5cedb01e71ee6d0013a6dbc60ec07618bd4e0))
* **org-config:** allow agent and update branches ([d17eb15](https://github.com/bitwise-media-group/github-settings/commit/d17eb15c93643d207aee949bfe2fcd5e218b1317))
* **org-config:** allow component version tags in org rulesets ([4c39ff0](https://github.com/bitwise-media-group/github-settings/commit/4c39ff04e74f76c28d5b0f55aaa5585d64579ea5))
* start protecting private repositories ([b88119f](https://github.com/bitwise-media-group/github-settings/commit/b88119f3a8ac06be6cd420f45a063fccb3929ecd))


### Bug Fixes

* **deps:** update bitwise-media-group/github-workflows action to v6.1.1 ([#25](https://github.com/bitwise-media-group/github-settings/issues/25)) ([4188ebb](https://github.com/bitwise-media-group/github-settings/commit/4188ebbc6daf0dc5595fd9194fd329d438e2ebeb))
* **workflows-sync:** never overwrite a reusable-workflow definition ([fa27b65](https://github.com/bitwise-media-group/github-settings/commit/fa27b654cdb4e853d35a7fe43d0afc10efcabb1a))

## [1.2.0](https://github.com/bitwise-media-group/github-settings/compare/v1.1.0...v1.2.0) (2026-07-01)


### Features

* **org-config:** wire add-to-project into org-sync ([7ffd544](https://github.com/bitwise-media-group/github-settings/commit/7ffd544e9ccc613830252942e56ef658a4376680)), closes [#6](https://github.com/bitwise-media-group/github-settings/issues/6)


### Bug Fixes

* **add-to-project:** also add opened pull requests to the Roadmap project ([3893b92](https://github.com/bitwise-media-group/github-settings/commit/3893b923889ac31ea63818d156fae3f2192aa1b9))

## [1.1.0](https://github.com/bitwise-media-group/github-settings/compare/v1.0.0...v1.1.0) (2026-06-29)


### Features

* **org-config:** support default maintainer team config ([5fa9e28](https://github.com/bitwise-media-group/github-settings/commit/5fa9e28bda263bdf18a4d1f396d2303dc438153b))
* **org-config:** update org policy ([6230aef](https://github.com/bitwise-media-group/github-settings/commit/6230aefbb6ba9ccfd280ad86b51d93e22fc024c3))
* **repo-config:** sync PR creation policy and Pages source ([b5222e3](https://github.com/bitwise-media-group/github-settings/commit/b5222e36ebe04c6f802f129f3c25ffcafbd124d8))


### Bug Fixes

* **rulesets:** match nested dependabot branches in public-fork-only ([034ccbb](https://github.com/bitwise-media-group/github-settings/commit/034ccbb4814d5cdff23206c5b505733ca4610e96))

## 1.0.0 (2026-06-16)


### Features

* add default rulesets ([f5a1243](https://github.com/bitwise-media-group/github-settings/commit/f5a1243404676aaf50866999cecb073f937f7fd1))
* add repo/org config scripts that sync settings and rulesets ([bdb685b](https://github.com/bitwise-media-group/github-settings/commit/bdb685b3e619a5b5a6b168a6669ebc5fe260fc86))
* **org-org:** restrict repository transfers ([d63813d](https://github.com/bitwise-media-group/github-settings/commit/d63813dd5d44bca562730d21839a7451cc050b0e))
* sync repo labels and add org-wide config fan-out ([bb85b6d](https://github.com/bitwise-media-group/github-settings/commit/bb85b6dcea2b1ae57a08c5fdaee4eb9917a78ce7))
