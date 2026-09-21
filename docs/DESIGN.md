# Claude Account Switcher — design notes

A macOS menu bar app for people with several Claude Code logins: it shows how much quota
each login has left and switches the live login in one click. MIT licensed.

*Anthropic has asked projects with Claude-like names to rename before. If that happens here,
rename then.*

**Status.** Built and in daily use: quota for every account, switching, in-app sign-in,
token renewal, rename/remove/reorder, and automatic switching. Not built: the gateway panel
and the widget (§6).

## 1. What it is for

Claude Code keeps one login live at a time. With three or four subscriptions that means a
terminal command to flip between them and no way to see what is left anywhere else. This app
does three things:

1. **Quota at a glance.** Every account's session window, weekly window, model-scoped limits
   and reset countdowns, all visible at once.
2. **Switching by clicking.** One click does what `claude-acct login <name>` does.
3. **Switching by itself**, when it is armed to: Failover when the live account is out of
   quota, Balance to spread usage so no window resets unused.

There is no command line: everything happens in the menu bar. macOS only, one user.
Portability does not matter and neither do competitors.

Out of scope: `setup-token` credentials (`claude-acct use`). They carry `user:inference`
only, so their quota can never be read (§3).

## 2. How it works

The mechanism came from `claude-acct` (a zsh function in `~/.config/claude-accounts/`) and is
now Swift. Both tools read and write the same keychain items, so either one can still switch.

- **An account is a keychain item.** `Claude Code Login: <name>` holds
  `{credentials, oauthAccount}` — the same shape `claude-acct capture` writes. The live login
  is Claude Code's own `Claude Code-credentials` item plus the `oauthAccount` key of
  `~/.claude.json`; `~/.config/claude-accounts/active-login` records which slot is live.
  Names are letters, digits, `.`, `_`, `-`: `claude-acct`'s own rule, so a name made here
  still works there.
- **A switch, in order:** take the lock → read and validate the target slot → read
  `.claude.json` and the live item → **save the live credentials back into the slot being
  left** → back up `.claude.json` → replace `oauthAccount` → write the live keychain item →
  move the marker → prune backups to the newest ten. The write-back is the step that must
  never be skipped: Claude Code rotates refresh tokens, so the only good copy of the account
  being left lives in the live item.
- **`.claude.json` is edited by byte span, not parsed.** It is 62 KB and 64 top-level keys.
  Parsing and re-encoding (what `jq` does) loses key order, re-escapes every path and turns
  `1.0` into `1`. Instead the byte range of the `oauthAccount` value is found in the raw file
  and only those bytes are replaced; the file is then re-read and compared key by key against
  what it held before, and a difference anywhere else fails the switch.
- **Rollback.** Nothing is written before the write-back and the backup. Each of the three
  writing steps is undone if the next fails: a failed keychain write restores `.claude.json`,
  a failed marker write restores both. A stale marker is the dangerous state — the *next*
  switch would save the new account's credentials into the old account's slot — so it is
  never left behind quietly.
- **Every keychain write is read back** and compared with what was written before the switch
  continues. A keychain that accepts a write and stores something else is not hypothetical
  (§3, `security -i`).
- **One lock**, `~/Library/Application Support/Claude Account Switcher/switch.lock` (flock, so
  a crash releases it), around switch, capture, rename and remove. It is mutual with
  `claude-acct` only once that function takes the same lock, which it still does not; the
  contention that actually occurs is the app against itself.
- **The marker is bookkeeping; the email is the truth.** `/login` inside Claude Code and
  `claude-acct login` both move the live login without touching the marker, so before saving
  anything back the app compares the marker's slot email against the account `.claude.json`
  says is live. If they disagree, the slot that really holds the live account receives the
  write-back; if no slot does, the switch is refused with nothing written.
- **Capture** stores the live login under a name: one keychain item and the marker, never the
  live item and never `.claude.json`.

## 3. What was measured

Expensive to learn, and not re-derivable from the code alone.

### The usage endpoint

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <access token>
anthropic-beta: oauth-2025-04-20
```

- **Scope.** Needs `user:profile`. Login slots have it; `setup-token` credentials get a 403
  with `oauth_scope_insufficient`.
- **Shape.** `limits[]` is the source of truth. Each entry carries `kind`
  (`session` | `weekly_all` | `weekly_scoped`), `percent` (**used**, not left), `severity`,
  `resets_at`, `scope.model.display_name`, `scope.surface`, `is_active`. The response also
  carries legacy `five_hour` / `seven_day` objects with no severity, plus `extra_usage`,
  `spend`, `seven_day_breakdown` and a dozen codenamed fields that are usually null.
- **Decode defensively.** An unrecognised `kind` is shown as-is with a note, a missing field
  shows "—", and only a response with no usable numbers at all is reported as "shape changed".
  The app must never crash on this response.

### Its rate limit

- **What it sends.** `HTTP/2 429`, body
  `{"error":{"type":"rate_limit_error","message":"Rate limited. Please try again later."}}`,
  and exactly one hint: **`retry-after: 0`**. No `x-ratelimit-remaining`, no reset timestamp,
  no `anthropic-ratelimit-*`; the response is Cloudflare-fronted and carries nothing else.
  A non-positive hint is therefore treated as absent.
- **What tripped it.** About 12 readings on one token inside 25 minutes — several app launches
  polling two accounts each, plus hand-run checks. One reading every two minutes never came
  close.
- **How long it lasts.** Long. After the first 429, eight probes two minutes apart over
  **16 minutes** were all 429; a 200 came only later. Assume tens of minutes, not seconds.

### The login flow, read out of the Claude Code binary (2.1.263)

- **One public client id for everything: `9d1c250a-e61b-44d9-88ed-5944d1962f5e`.** No
  `client_secret` appears anywhere in the login code; PKCE is the only thing binding a code to
  the app that asked for it. (`22422756-…` is the local-development counterpart, `59637612-…`
  is the separate design client, and the all-zeros uuid is a "not configured" placeholder, not
  a client id.)
- **PKCE S256, unconditionally.** `code_challenge_method` is a literal; there is no `plain`
  branch. Verifier is `base64url(32 random bytes)`, 43 characters.
- **Loopback on a port the OS picks.** Claude Code listens on `127.0.0.1:0` and sends
  `http://localhost:<that port>/callback` — a different port every login — so arbitrary-port
  loopback must be registered for this client (RFC 8252 §7.3). The hostname it sends is
  **`localhost`, not `127.0.0.1`**: different strings to an authorization server, so this app
  sends `localhost` too and binds `127.0.0.1`.
- **Authorize:** `https://claude.com/cai/oauth/authorize` (307 to claude.ai, query untouched)
  with `code=true`, `client_id`, `response_type=code`, `redirect_uri`, `scope`,
  `code_challenge`, `code_challenge_method=S256`, `state`.
- **Exchange:** `POST https://platform.claude.com/v1/oauth/token`, **`application/json`** (not
  form-encoded), body `{grant_type, code, redirect_uri, client_id, code_verifier, state}`. No
  Authorization header, no secret. The same endpoint serves the refresh grant
  (`{grant_type: refresh_token, refresh_token, client_id}`), which **rotates the refresh
  token**; a dead one answers `invalid_grant`.
- **Profile:** `GET https://api.anthropic.com/api/oauth/profile`. Its `account` and
  `organization` objects become the slot's `oauthAccount`, mapped key by key with **no
  invented nulls** — a switch splices that value into `~/.claude.json`, so a key we make up is
  a key the owner loses.
- **Scopes: the five a subscription login is granted** — `user:profile user:inference
  user:sessions:claude_code user:mcp_servers user:file_upload`. Claude Code also asks for
  `org:create_api_key`, which a claude.ai subscription is not granted and this app has no use
  for.
- **Paste fallback, as Claude Code's own:** `redirect_uri=https://platform.claude.com/oauth/code/callback`
  displays the code on screen; the string to paste is `<code>#<state>` and both halves are
  required.
- **Not confirmed without signing in:** claude.ai's authorize endpoint answers curl with a
  Cloudflare challenge, and platform.claude.com returns its 200 shell for a bogus `client_id`
  and a bogus `redirect_uri` alike — validation happens after the login gate. "Arbitrary
  loopback is registered" therefore rests on Claude Code's own random-port behaviour: strong,
  but indirect.

### `security -i` truncates

One slot was found holding exactly 3,955 characters of invalid JSON — the input line limit of
`security -i` cutting a long payload, silently, with exit 0. That is why every write goes
through an argument and is read back (§4.2).

## 4. Decisions, and why

### 4.1 A click switches; safety is Undo, not a confirmation

`claude-acct login` never asked, and a six-step confirmation in front of every switch read as
a wall. So a plain click on a row switches immediately, and the footer offers **Undo** for
15 s — the reverse switch, rotated credentials saved on the way. **⌥-click** shows the dry run
first for anyone who wants it; the plan is handed back at confirmation time and the switch is
refused if the world moved in between. A row that cannot be switched to (the live one, or
anything corrupt) opens its numbers instead, so a click is never a dead end.

### 4.2 Everything through `/usr/bin/security`

- **Item data is read** with `security find-generic-password -w`, and **written** with
  `security add-generic-password -U … -w <payload>`.
- **Why not Security.framework.** `SecItemAdd` creates an item whose access list names only
  the binary that created it. This app reads through `security`, which is then *not* on that
  list, so every poll raised a keychain dialog and a write could not be read back to verify
  it. Items written by `security` carry the same access list as Claude Code's own, and nothing
  prompts.
- **Why not `security -i`.** Its input line limit is what truncated a slot to 3,955 bytes and
  cost an account. The payload goes on the argument list instead: visible in `ps` for the
  length of one call, which on a single-user Mac is the narrower risk. A payload that is not
  UTF-8, or contains a NUL, is refused outright — an argument stops at the first NUL and
  `security` would store the truncation and exit 0.
- **What still uses the framework.** Enumerating services (attributes only, which never
  prompts); and the one-time repair of items an earlier build created with `SecItemAdd`: read
  it back with `kSecUseAuthenticationUIFail`, delete, rewrite through `security`, read back —
  at most one attempt per item per launch, with the bytes restored if the rewrite cannot
  finish. That repair read is the only call left that can raise a dialog.
- **Every keychain call is logged** to `keychain.log` in the app's support directory: service,
  operation, outcome, and a `PROMPTED` marker when a call took more than 1.5 s, which means it
  sat behind a dialog. Never a payload, a token or an email. Always on — the prompt this
  exists to explain appears while the app is being used, not while anyone is watching a
  terminal.

### 4.3 The menu bar is a mark, not a readout

The first version put `work 5h 75% wk 29% ⊘Fable` in the bar at 198 pt. A busy menu bar
answers running out of room by collapsing items behind a `«` chevron, widest first, and a
status item you cannot see is worth nothing however much it says. The item is now the drawn
mark alone, 24 × 18 pt, which cannot be pushed off.

What stays in the bar is colour, because it costs no width: a small **severity dot** on the
mark, amber or red, from **the server's own `severity`** on the windows that stop all work,
worst one wins. Our own thresholds — 25% or more left normal, 10–25% amber, under 10% red —
are the fallback for a severity we do not recognise and for the legacy `five_hour`/`seven_day`
fields, which carry none. A model-scoped limit never votes on the colour: it stops one model,
not everything. With no dot the image is a template, so macOS inks it for the bar and it looks
native.

The readout itself did not die: `MenuBarLabel` still builds the same string, with its own test
suite, and it is the status item's **tooltip** (plus the `CAS_LOG` line). Both windows always
appear, always as remaining, always labelled; a window with no usable reading shows `?%` and
no reading at all shows `<account> ?`. Nothing is ever invented. Cached or stale readings get
their age appended, dimmed; the colour never changes for age.

### 4.4 A row is a row, not a card

One tall card per account — paragraphs, three bars, four buttons — read as a settings sheet
and did not survive the question "what do twenty accounts look like?". A two-level ring
replaced it and nobody could read it: two unlabelled arcs and a notch is a legend you have to
learn before a row means anything. **Labelled micro-bars need no legend**, so that is what a
row is: 400 pt wide, one account per 50 pt row.

```
work ●                                                47 m
Session ▇▇▇▇▇▇▇▇░░ 83%        Week ▇▇▇░░░░░░░ 31%
Fable   ░░░░░░░░░░░░░░░░░░░░░░░░░  0%
```

- **The name**, semibold with a 4 pt dot when it is the live login.
- **Two labelled bars**: a word (`Session`, `Week` — never `5h` or `wk`), a 3 pt track filled
  with what is LEFT, the percentage at the trailing edge in monospaced digits so numbers read
  as a column down twenty rows. **A bar takes a severity colour only when its own window is in
  trouble**, judged per limit, so a healthy row has no colour in it at all. No reading is an
  empty track and a `—`. Hovering a bar gives that window's reset time.
- **One short right-aligned thing**: the tightest reset (`47 m`, `3 h`, `2 d`), or the state
  (`expired`, `corrupt`, `needs re-login`, `unreadable`) with a severity dot. A state outranks
  a countdown — a countdown on an account that cannot run is a lie of omission.
- **A used-up model is a third bar** on its own line, labelled with the model's own name and
  `+N` when several are spent (that row is 68 pt). Three bars abreast would leave each track
  22 pt, and legibility is the whole reason the ring went.
- **A row that cannot show numbers wears its fix** where the countdown would be: `Renew` on an
  expired inactive slot, `Log in` on a corrupt one or a dead refresh token, `Retry save` in
  amber where a rotation is held in memory. Hover is the wrong control for the one state you
  notice rather than go looking for. A corrupt slot is never offered a renewal: there is
  nothing in it to renew.
- **Hover reveals icon buttons** at the trailing edge (renew, capture, rename, remove,
  numbers); whatever the labelled button already offers is left out, and **right-click offers
  the same by name**, because a hover-only control is a control nobody finds. Drag reorders.
- **The numbers and the prose are behind the disclosure arrow**: email, plan tier, every limit
  as "83% left · 47 m", the age of the reading, the health problem. Text, not bars.
- **The list scrolls past 480 pt** (about eight rows) and the footer stays put, so three
  accounts and twenty differ only in how far the list runs. There is no header: the active
  account is the first row and its numbers are on it. The only legend is behind the footer's
  **?**, off by default.
- **The footer** holds Refresh all and the Keep-up-to-date switch (with the sweep's progress
  and its report in their place while they run), a small `Mode:` popup — a segmented control
  was the loudest thing on screen for something that usually does nothing — a **+**, the ?,
  read-now and quit icons, the one-line ToS note when the mode is not Manual, and the last log
  line with the rest behind an arrow.
- **Type and colour.** One family, three sizes (13 pt names, 11 pt numbers, 10 pt labels),
  weight rather than colour for hierarchy, no all-caps, 8 pt rhythm, no separators, hover as
  the only highlight.

The panel is an `NSPanel` built at launch and positioned by hand, not `MenuBarExtra(.window)`:
that builds its content on the first click and animates its own activation, which is where
missed first clicks and the slide came from. It resizes to its content while open, and hides
on Esc, on an outside click, and when another app comes to the front — but never on our own
activation, which turned every click into a no-op.

### 4.5 A window past its reset is empty again

Every reading is rolled forward to now before anything draws or judges it: a limit whose
`resets_at` has passed counts as 0% used, severity normal, no reset time. The quota came back
on a schedule the server itself gave us, so arithmetic beats a stale number — otherwise an
account that has just refilled shows "4% left", the countdown points at a window that is
already back, and the policy switches away from the best account on screen. The panel
re-renders every 30 s so this happens with the panel open, and it costs no request.

### 4.6 One rate-limit allowance for the whole app

All accounts share one budget, because the endpoint's limit is per token-holder, not per row.

- **At most one request per pass**, with a **30 s floor** between any two requests whichever
  account they are for. The per-account cadence — active every 2 min, every 30 s below 15%
  left, inactive every 10 min — is a ceiling, not a rate.
- **Which account goes next** is the one furthest past its own interval, as a ratio. Preferring
  the active account outright starved the others: it falls due every two minutes, so it won
  every turn. Judged on the last *attempt*, not the last success, so one failing account
  cannot starve the rest.
- **After a 429** the budget closes for 2 → 4 → 8 → 15 min with up to 20% jitter, never
  shortening a wait already running, and a success clears the strikes. `Retry-After: 0` is
  treated as absent.
- **The budget survives a relaunch** (in `UserDefaults`, clamped on restore so a wrong clock
  cannot lock the app out for good), because restarting in a loop is how the endpoint
  rate-limited us in the first place.
- **Failures show as age, not as blanks.** The last good reading per slot is cached on disk
  (`usage-cache.json`, 0600 in a 0700 directory, written atomically, percentages and reset
  times only — no tokens, no emails), so a fresh process renders real numbers with their age
  instead of a question mark.

### 4.7 Renewals are opt-in, because every renewal rotates a refresh token

An inactive slot's access token expires in hours; renewing it consumes the stored refresh
token and issues a new one, killing the old instantly. So there are exactly four ways a
renewal happens, all inside the one allowance:

- **The row's Renew button.**
- **Refresh all**: plans each slot first (stalest first; anything read in the last 150 s is
  left alone; a corrupt slot, a dead refresh token or a scope that cannot read usage is a
  skip with its reason), then works strictly one request at a time, counting out the 30 s
  floor in the footer, stopping dead on the first 429, and reporting what was renewed, what
  was already fine and what was left as it was. Stop stops *after* the call in flight: a
  rotation already on the wire has to be written back or the account is left holding a retired
  token.
- **Opening the panel**, if any inactive account has gone dark — at most one sweep per ten
  minutes. An account left overnight otherwise shows nothing until a button is pressed, which
  defeats a panel whose whole point is showing every account at once. Opening it counts as
  asking; closed, the app still renews nothing.
- **Expired accounts are renewed without being asked**: at most one every five minutes, the stamp kept on disk so a relaunch is not a way to rotate another token. It was an opt-in switch until the owner asked for it to simply be on.
  disk so relaunching the app is not a way to rotate another token.

**A rotation that cannot be stored is not lost.** The write is tried twice; after that the new
tokens are held in memory, the row wears an amber `Retry save`, and the retry writes them with
no further network call — another rotation would retire the only working copy.

**The live account is never refreshed by this app.** Claude Code owns that item and its
refresh lock; if the live token has expired the app waits and shows the last known value.

### 4.8 Sign-in writes one slot and nothing else

The app performs the flow from §3 itself, so adding or repairing an account never needs a
terminal.

- **It never touches** `Claude Code-credentials` (its writer literally cannot reach that
  service), `~/.claude.json`, or the active-login marker. Adding an account does not change
  which account is in use.
- **Nothing is written before the email is on screen.** The exchange and the profile fetch
  happen first, the panel shows who came back, and only the button under it writes.
- **A name that already holds a readable login is refused before the browser opens.** A
  corrupt slot, or one whose refresh token is dead, is replaceable — replacing it *is* the
  repair. The live slot is refused outright: it must go on mirroring the live item.
- The paste fallback is offered from the waiting screen and taken automatically if no port can
  be bound. One PKCE pair per sign-in, kept when the paste page is opened mid-wait; each run
  carries an id, so a reply from an abandoned run cannot land on the next one.
- A login whose email is already stored under another name gets a warning: two slots for one
  account share one quota and the panel would double-count it.

### 4.9 Automatic switching is armed, capped, and disarms itself

Manual is the default and switches nothing. Failover and Balance may switch on their own, and
selecting either shows a plain-text note that automatic rotation might break Anthropic's terms
— no modal, nothing to accept.

- **Failover** switches only when the live account cannot continue: session at 100%, weekly at
  100%, or credentials that cannot log in.
- **Balance** is water-filling. For each eligible account,
  `urgency = weekly_remaining% / hours_until_weekly_reset` (the whole remainder when no reset
  time is known, so it is used before it is thrown away); highest urgency wins, and the
  dragged list order breaks a tie. Routing work to an account lowers its urgency until the
  next one overtakes, which evens the burn rates out.
- **Eligible** means at least 5% session and 2% weekly left. **Hysteresis**: the challenger
  must beat the incumbent by more than 25%. **Cool-off**: no two switches inside 15 minutes
  unless the live account is stuck — and clicks count, because two credential rewrites close
  together is the failure mode worth fearing.
- **The gate is the only path from a decision to a switch.** It also refuses while a sweep, an
  action or a confirmation is running, and above **four automatic switches an hour**.
- **Two failed automatic switches in a row put the mode back to Manual** and say so in a
  notification. A loop that keeps rewriting credentials is the worst thing this app could do.
  Choosing a mode again re-arms it.
- **Notifications are only for what the owner did not do.** Authorisation is asked the first
  time one is warranted, never at launch, and a refusal is final for that run.
- **What the policy cannot see:** which model a running session is using. `blockedForModelInUse`
  is therefore always false — a model-scoped limit at 100% never counts as blocking in the
  decision, though the row and the mark both show it.

### 4.10 Rename, remove, reorder

All three live with the other per-row actions: hover icons and right-click.

- **Rename** is a write under the new name and a delete of the old, in that order — a slot's
  name *is* its keychain service. The old item goes only once the new one has been read back
  byte for byte, so a failure before that leaves the account exactly where it was; a failure
  after it leaves a duplicate, which is a mess and not a loss, and the row says so. Renaming
  the live slot moves the marker in the same operation (a marker naming a slot that no longer
  exists would leave the next write-back homeless); if the marker cannot be moved, the copy is
  deleted again. A taken, invalid or unchanged name is refused before anything is written, and
  so is a slot holding rotated tokens that are not saved yet — they are keyed to the old name.
- **Remove** deletes that one keychain item and nothing else: not the live item, not
  `.claude.json`, not the marker. It refuses the live account twice over — the marker naming
  it, or its stored email matching the live one. It is the only irreversible action, so the
  row asks inline (name, email, Remove/Cancel) rather than opening a sheet. A corrupt or
  unreadable slot can be removed; that is the point.
- **Reorder** is a drag, stored in `UserDefaults` as a list of names. An account with no stored
  place sorts last, in the order the keychain gave it. The row index is what the policy gets
  as its tie-breaker, so dragging an account up is what decides a Balance tie. A rename keeps
  the account's place; a removal takes it out.

## 5. What is built

| Part | Notes |
|---|---|
| App | Swift + SwiftUI in an AppKit shell: `NSStatusItem`, a hand-positioned `NSPanel`, `UserNotifications`. macOS 14+, Swift 6 toolchain, SwiftPM, no Xcode project |
| `SwitcherCore` | `SlotStore` and `Keychain`/`KeychainWriter` (the `security` path, §4.2), `UsageClient` + `UsageDecoder` + `UsageCache`, `TokenRefresher` (single-flight, atomic write-back, in-memory rescue), `RateLimitBudget`, `RefreshSweep`, `OAuthLogin` + `PKCE` + `LoopbackCallback` + `LoginSlotWriter`, `Switcher` (swap, capture, rename, remove), `JSONSplice`, `PolicyEngine` and `AutoSwitchGate` (both pure), `MenuBarLabel`, `QuotaBars` |
| Signing | `scripts/make-signing-identity.sh` creates a self-signed code-signing identity in the login keychain, so every build carries the same signature and a keychain "Always Allow" survives a rebuild. Without it, builds are ad-hoc signed and the signature changes every time |
| Tests | ~200 cases run by `scripts/test.sh` (Command Line Tools ship no `xctest` host, so a small runner hosts swift-testing directly). Policy, gate, decoding against a redacted fixture, budget, sweep planning, the OAuth flow against a stubbed session, and whole switches, captures, renames and removals against an in-memory keychain in a temporary directory. The real keychain is only touched with `CAS_KEYCHAIN_TESTS=1`, and then only under `CAS Test Login: ` |

## 6. What is not built

- **Gateway panel (claude-code-api).** Running `codingworkflow/claude-code-api` from the GUI:
  port picker (8787 default, warning on 8000 and 8955, which are taken here), `127.0.0.1` by
  default because the gateway's own default is `0.0.0.0` with auth off, a generated API key in
  the keychain, a LaunchAgent with its own working directory so the DB and logs stop landing
  in the clone, adopt-or-replace for an instance already listening, health and log tail, and
  copyable example commands. **The app would never vendor its code**, so its GPL does not
  reach this repo. Accounts come for free: the gateway spawns `claude` per request, so it
  follows whatever the live login is.
- **Widget and history.** SQLite samples over 30 days, a burn-rate projection ("at this pace
  this account hits the weekly cap at 18:40"), a sparkline, and a WidgetKit widget reading a
  snapshot from an App Group container — no network calls of its own. Nothing of this exists
  yet: no database, no widget target.
- **Dropped on purpose.** A compact menu bar style with one mini bar per account: there is no
  width for it (§4.3).

## 7. Risks and unknowns

- **Undocumented endpoint.** `/api/oauth/usage` is internal and full of codenames, so any
  Claude Code release can change it. Mitigated by the defensive decoder, a "shape changed"
  banner instead of wrong numbers, and a record of the version it was read against (2.1.263).
- **Refreshing tokens outside Claude Code.** For inactive slots the app uses Claude Code's own
  public OAuth client, which Claude Code itself never does for those slots. Only metadata
  calls go through it — inference always goes through the real `claude` binary — but Anthropic
  has cracked down on third-party use of subscription OAuth before, so the account risk is not
  zero.
- **Terms.** Manual switching is the everyday flip and needs nothing more. Automatic rotation
  gets the in-app side note and the same line in the README, and nothing heavier.
- **Prompt cache.** If a running session does follow a switch, its next turn re-caches the
  whole context on the new account, which can cost a noticeable chunk of session quota at
  once. The app cannot see sessions at all, so it cannot avoid this: the 15-minute cool-off
  and the four-an-hour cap are the only brakes, and they are blunt ones.
- **Unknown: whether a running session follows a switch.** Never measured. Every new `claude`
  process picks the new login up — terminals, the editor panel, a gateway — but the panel says
  the conservative thing about running ones, and that claim is inference, not measurement.
- **Secrets on the argument list** for the duration of one `security` call (§4.2), and
  **rotated tokens in memory** when the keychain refuses a write. Both are chosen trade-offs
  against worse failure modes, and both are visible in the UI or the audit log.
