### Allowed Prefixes

Prefixes are **off by default**. Do not add one after the emoji unless the user explicitly asked for a combo with conventional commits or conventional prefixes. When combo mode is explicitly requested, pick from this list:

| Prefix | Use When |
|--------|----------|
| `init:` | Initial setup or configuration of something new |
| `content:` | Endpoint definitions, DTOs, contracts, data shapes |
| `style:` | Code formatting, cleanup, aesthetic changes |
| `fix:` | Bug fixes |
| `refactor:` | Restructuring without behavior change |
| `docs:` | Documentation, XML comments, OpenAPI annotations |

Examples in the emoji tables below use the default no-prefix form. Only switch to `<emoji> <prefix>: ...` when the user explicitly asked for that combo.

### Emoji Selection — Gitmoji First, Fallback Second

**Always prefer an official [gitmoji](https://gitmoji.dev) emoji** when the semantic meaning is a good fit. Only use a non-gitmoji emoji when no official entry matches well enough.

#### Primary: Gitmoji

| Emoji | Gitmoji code | Use when | Example |
|-------|-------------|----------|---------|
| 🎉 | `:tada:` | Begin a brand-new project | `🎉 begin api project` |
| ✨ | `:sparkles:` | **ONLY for 100% new feature introduction** — a capability that did not exist before. NOT for bug fixes, enhancements to existing features, documentation updates, skill description clarifications, or refactors of existing code. | `✨ add user submission endpoint` |
| 🎨 | `:art:` | Code style, formatting, structure cleanup | `🎨 format endpoint modules` |
| ⚡️ | `:zap:` | Improve performance | `⚡️ optimize query execution in repository` |
| 🐛 | `:bug:` | Fix a bug | `🐛 handle null optional fields in dto` |
| 🩹 | `:adhesive_bandage:` | Simple fix for a non-critical issue | `🩹 correct default value in config` |
| 🚑️ | `:ambulance:` | Critical hotfix | `🚑️ patch auth bypass vulnerability` |
| ✏️ | `:pencil2:` | Fix typos | `✏️ correct typo in error message` |
| ♻️ | `:recycle:` | Refactor code, restructure existing logic without behavior change, or reorganize existing skill content | `♻️ extract mapper to separate class` |
| 🚚 | `:truck:` | Move or rename files, folders, or resources | `🚚 rename auth module to identity` |
| 🔥 | `:fire:` | Remove code or files | `🔥 remove deprecated submission handler` |
| ⚰️ | `:coffin:` | Remove dead code | `⚰️ remove unused dto properties` |
| 🗑️ | `:wastebasket:` | Deprecate code that needs cleanup | `🗑️ deprecate v1 submission endpoint` |
| 📝 | `:memo:` | Documentation, inline comments, API annotations, docs prose, and clarity improvements to existing guidance (skill descriptions, readmes, code comments) that is not primarily repo-health or release-status communication | `📝 add inline docs to submission handler` |
| 💡 | `:bulb:` | Add or update inline comments | `💡 add comments to submission processing logic` |
| 💬 | `:speech_balloon:` | Community health, changelog, release-status communication, and other human-facing repo messaging; also user-facing text literals | `💬 update changelog and community guidance` |
| 🔧 | `:wrench:` | Configuration files (app config, environment settings) | `🔧 configure swagger and versioning` |
| 🔨 | `:hammer:` | Add or update development scripts | `🔨 add build script for release packaging` |
| ➕ | `:heavy_plus_sign:` | Add a package dependency | `➕ add validation library` |
| ➖ | `:heavy_minus_sign:` | Remove a package dependency | `➖ remove unused logging package` |
| ⬆️ | `:arrow_up:` | Upgrade package dependencies | `⬆️ upgrade dependencies to latest` |
| ⬇️ | `:arrow_down:` | Downgrade dependencies | `⬇️ downgrade ef core to stable release` |
| 📌 | `:pushpin:` | Pin dependencies to specific versions | `📌 pin node version to 20 lts` |
| 🗃️ | `:card_file_box:` | Database changes, ORM models, migrations, entities | `🗃️ add submission entity and db context` |
| 🌱 | `:seedling:` | Add or update seed files | `🌱 add initial request table migration` |
| ✅ | `:white_check_mark:` | Add or update tests | `✅ add integration tests for submission api` |
| 🧪 | `:test_tube:` | Add a failing test (TDD red phase) | `🧪 add failing test for null notes field` |
| 🦺 | `:safety_vest:` | Validation code | `🦺 add submission dto validation rules` |
| 🥅 | `:goal_net:` | Catch errors | `🥅 add global exception handler middleware` |
| 👔 | `:necktie:` | Business logic, service layer, domain code | `👔 add submission processing service` |
| 🏷️ | `:label:` | Add or update types, interfaces, contracts (type-only) | `🏷️ add submission dto contracts` |
| 🔒️ | `:lock:` | Security or privacy fixes | `🔒️ prevent open redirect in login` |
| 🔐 | `:closed_lock_with_key:` | Add or update secrets | `🔐 add key vault secret references` |
| 🛂 | `:passport_control:` | Authorization, roles, and permissions | `🛂 add role-based access policy` |
| 🚨 | `:rotating_light:` | Fix compiler or linter warnings | `🚨 resolve nullable warnings in handler` |
| 💚 | `:green_heart:` | Fix CI build | `💚 correct test runner config in pipeline` |
| 👷 | `:construction_worker:` | Add or update CI build system | `👷 add github actions workflow` |
| 🚀 | `:rocket:` | Deploy stuff | `🚀 deploy request api to staging` |
| 🏗️ | `:building_construction:` | Make architectural changes | `🏗️ restructure to clean architecture` |
| 🧱 | `:bricks:` | Infrastructure related changes | `🧱 add terraform modules for staging` |
| 📦 | `:package:` | Add or update compiled files, packages, or package release-note metadata | `📦 update nuget package output config` |
| 💄 | `:lipstick:` | Add or update the UI and style files | `💄 update button styles` |
| ♿️ | `:wheelchair:` | Improve accessibility | `♿️ add aria labels to navigation` |
| 📱 | `:iphone:` | Work on responsive design | `📱 add mobile breakpoints` |
| 🌐 | `:globe_with_meridians:` | Internationalization and localization | `🌐 add resource files for localization` |
| 🔖 | `:bookmark:` | Release / version tags | `🔖 tag v1.2.0 release` |
| 💥 | `:boom:` | Introduce breaking changes | `💥 remove deprecated v1 api endpoints` |
| ⏪️ | `:rewind:` | Revert changes | `⏪️ revert submission handler refactor` |
| 🔀 | `:twisted_rightwards_arrows:` | Merge branches | `🔀 merge feature branch into main` |
| 📄 | `:page_facing_up:` | Add or update license | `📄 add mit license` |
| 🙈 | `:see_no_evil:` | Add or update a .gitignore file | `🙈 add build output to gitignore` |
| 🔊 | `:loud_sound:` | Add or update logs | `🔊 add request logging middleware` |
| 🔇 | `:mute:` | Remove logs | `🔇 remove verbose debug logging` |
| 🩺 | `:stethoscope:` | Add or update healthcheck | `🩺 add health endpoint for readiness probe` |
| 🚩 | `:triangular_flag_on_post:` | Add, update, or remove feature flags | `🚩 add feature flag for new search` |
| 👽️ | `:alien:` | Update code due to external API changes | `👽️ adapt to new payment api contract` |
| 🧵 | `:thread:` | Multithreading or concurrency code | `🧵 add async processing pipeline` |
| 🍱 | `:bento:` | Add or update assets | `🍱 add logo and icon assets` |
| 🦖 | `:t-rex:` | Code that adds backwards compatibility | `🦖 add v1 compatibility shim` |
| ✈️ | `:airplane:` | Improve offline support | `✈️ add service worker for offline mode` |
| 🚸 | `:children_crossing:` | Improve user experience / usability | `🚸 simplify onboarding flow` |
| ⚗️ | `:alembic:` | Perform experiments | `⚗️ spike alternative caching strategy` |
| 🚧 | `:construction:` | Work in progress (avoid where possible) | `🚧 wip: partial submission module setup` |

#### Fallback: Extended Emoji Reference

When no gitmoji entry fits, consult **[this curated extended reference](https://gist.github.com/marcellodesales/aba1152a91d69f9b39745a08fd73a6f9)** — a multi-source collection covering languages, platforms, cloud infra, and programming strategies that gitmoji doesn't address.

Key entries from that reference, by category:

**Bootstrapping & infrastructure**

| Emoji | Use when | Example |
|-------|----------|---------|
| ⚙️ | App bootstrapping / host setup (distinct from 🔧 config files) | `⚙️ setup app host and middleware` |
| ☁️ | Cloud provider setup or changes | `☁️ add cloud secrets integration` |
| ☸️ | Kubernetes | `☸️ add k8s deployment manifests` |
| 🎡 | Helm charts | `🎡 add helm chart for api service` |
| 🧮 | Lambda / serverless functions | `🧮 add serverless function trigger` |

**Containers & deployment**

| Emoji | Use when | Example |
|-------|----------|---------|
| 🐳 | Docker | `🐳 add dockerfile for api deployment` |

**Data & storage**

| Emoji | Use when | Example |
|-------|----------|---------|
| 🛢 | General database (when 🗃️ feels too narrow) | `🛢 add request storage schema` |
| 🐘 | PostgreSQL-specific | `🐘 add postgres connection config` |

**Documentation**

| Emoji | Use when | Example |
|-------|----------|---------|
| 📚 | High-level docs, README, wiki (use 💬 instead when the change is mainly changelog or community-health communication) | `📚 add api usage documentation` |

**Observability & runtime**

| Emoji | Use when | Example |
|-------|----------|---------|
| 🪵 | Structured logging setup | `🪵 add structured logging setup` |
| 📢 | Notifications or event publishing | `📢 add submission event notification` |
| 🏃 | Background workers or hosted services | `🏃 add background worker for processing` |

**Patterns & architecture**

| Emoji | Use when | Example |
|-------|----------|---------|
| 🧩 | Components, modules, DI registrations | `🧩 register services in di container` |
| 🏭 | Factory patterns | `🏭 add submission handler factory` |
| 📆 | Schedulers, cron, background jobs | `📆 add cron scheduler for cleanup job` |
| 🤖 | AI / ML integrations | `🤖 add openai client integration` |

**AI / tools (when relevant)**

| Emoji | Use when | Example |
|-------|----------|---------|
| 🦾 | AI prompt or agent code | `🦾 add ai prompt template for request triage` |
| 🧠 | LLM integrations | `🧠 integrate chatgpt for request classification` |

> When in doubt between two options, pick the emoji whose meaning most
> closely matches *what the change actually does*. If nothing fits, use 🎭
> (`:performing_arts:`) as a last resort and note the intent in the
> message.
