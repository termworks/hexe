# Changelog

## [0.0.20] - 2026-07-11

### <!-- 0 -->⛰️  Features

- Auto-reconnect and restore session on ses loss
- Project .hexe.lua trust ledger + hexe allow
- Highlight all visible search matches
- Multibyte-correct search prompt rendering
- Highlight current search match cells (3.3)
- Expose search.enter lua action + docs
- Wire scrollback search UI + lifecycle (3.3)
- Scrollback search core + state (3.3)

### <!-- 1 -->🐛 Bug Fixes

- Refuse ambiguous uuid prefix on kill path
- Purge fd bookkeeping before force-detach close
- Note cli fd closes; cloexec txlog fds
- Route pane frames through vt queue, no direct writes
- Nonblocking bounded uplink writes + shp read budgets
- Reconnect under fresh id to avoid self-steal
- Cloexec on sockets and instance lock fd
- Pid-identity guard for sweep/kill; heal VT-only loss
- Canonical on_start hooks + single .hexe.lua execution
- Bounded response writes to wedged clients
- 500ms handler read budgets, was 2-10s loop stalls
- Bounded uplink writes so wedged ses cannot freeze pod
- Replay pushes swallowed by sync readers
- Bounded retry on transient adoptPane failures
- Dirty-mark snapshot mutations for crash persist
- Probe pod socket, not just pid, before restore
- Empty reattach id must not match arbitrary session
- Restore float tab_visible bitmask; snapshot round-trip tests
- Stop advertising unimplemented pixel_render
- Backpressure mux->pod VT writes

### <!-- 2 -->🚜 Refactor

- Extract float-style parsers from api_bridge
- Extract layout parsers from api_bridge
- Extract record C-API from api_bridge
- Extract layout commands from com.zig
- Extract SesClient pane queries
- Extract statusbar lua-eval prims
- Extract SesClient sync readers
- Extract SesClient pane commands
- Extract SesClient session commands
- Extract SesClient response store
- Split server.zig handlers

### <!-- 3 -->📚 Documentation

- Finalize dispositions (1.2/1.8/2.1/2.4/2.5)
- Trust ledger (1.9) done + usage
- Resolve 2.6 config_v2 decision + scope
- 3.1 remote attach wired end-to-end
- Highlight all visible matches done
- Search prompt utf8 done, 3.3 complete
- Search match highlight done
- Scrollback search done (3.3)
- Record api_bridge module split
- Record com + api_bridge splits
- Frontend_client split done (-41%)
- Record SesClient reader extraction
- Mark 2.4 backpressure landed

### <!-- 6 -->🧪 Testing

- Frontend-death park/reattach smoke
- Live daemon-crash reconnect smoke harness
- RemovePaneFromSessionSnapshot float + tiled-collapse paths
- NormalizeAfterPaneRemoval + firstLayoutPaneUuid/paneUuidInList
- RemovePaneFromDetachedSessions prune + empty-delete
- Sanitize/sanitizeWithFallback edge cases
- ResolveSessionName empty/whitespace/cascade edges
- ReplaceSplitPane/setSplitRatio/removeFloat (client snapshot complete)
- Mux-root reads every float field (distinct values)
- Client-snapshot invalid-input error/no-op paths
- Adversarial sticky_pwd/socket JSON escaping
- Multi-level layout op selection (ratio/replace/split)
- FromJson corrupt/malformed input robustness
- Adversarial snapshot round-trips (escaping/boundaries)
- Client snapshot syncFloat (update-in-place) + removeTab reindex
- Client snapshot addTab/renameTab/splitPane + parent_tab reindex
- Detach/Reattach/SessionReattached round-trips
- AllocPaneId + two-generation closed-fd shield
- Saved-layout template restore (build/count/cwds)
- Pane-remove collapse + split-ratio anchors
- Frontend-reattach (mux-root) snapshot parse
- Persist crash-recovery snapshot round-trip
- Extract + characterize countSessionLayoutPanes
- Layout-tree ops (split/replace/contains/node-json)
- Snapshot restore robustness (malformed/partial/forward-compat)
- Extract + characterize reattach reconciliation (1.8)
- Characterize segment parser (2.6 safety net)
- Exit search before freeing borrowed screen

### Build

- Make smoke target for live e2e tests

## [0.0.17] - 2026-06-10

### <!-- 0 -->⛰️  Features

- Improve float reveal fluidity and correctness
- Improve mouse interaction and multiplexer queue handling
- Introduce host adapter abstraction for frontends
- Enhance shared float ownership and lifecycle
- Support session base root for attach and list commands
- Improve session reattach and persistence reliability
- Migrate live config to single files
- Redesign `hexe.setup` for a unified Lua configuration
- Improve shell-death respawn logic and terminal performance
- Add TabFocusKind and Floating UUID Preservation
- 11h codex hardening
- Reject session_* ops with unknown uuids
- Reject cross-uid peers on ses socket
- Enable custom border characters for floats
- Implement structured logging with logly integration
- Implement multiplexer VT write queue
- Implement session renaming from layout config
- Enhance layout save and session naming
- Add functionality to load layouts from local config
- Refactor session layout configuration
- Implement layout saving with scope selection
- Add interactive prompt for local config loading
- Externalize layout and keybinding configuration
- Introduce layout commands for session management
- Cache status bar Lua evaluations

### <!-- 1 -->🐛 Bug Fixes

- Improve session float stability and reconciliation
- Restrict pod metadata and asciicast to 0600
- Enforce payload caps and load-time bounds
- Memory-safety fixes in ipc and pty
- Forward space via text fast path
- Improve CLI argument parsing and help output
- Improve float exit key handling and title rendering
- Defer session snapshot application to avoid blocking
- Improve float configuration and visual inheritance
- Improve session config and layout handling
- Improve float pane lifecycle and exec errors
- Refactor and improve local layout loading logic

### <!-- 2 -->🚜 Refactor

- Prefer snapshot values in projection getters
- Log and close on wire write errors

### <!-- 3 -->📚 Documentation

- Add hardening plan
- Update terminology from "mux" to "terminal frontend"
- Close frontend runtime rewrite

### <!-- 6 -->🧪 Testing

- Extract fast_path and cover space-key regression
- Add wire round-trip and txlog corruption tests

### <!-- 7 -->⚙️ Miscellaneous Tasks

- Prune stubs, dead msg types, unused args
- Remove `--focus` flag for floats
- Make view structs explicitly visual
- Reconcile views from projection

### Build

- Drop leftover remote dependency wiring

### Cli

- Make terminal the frontend command

### Core

- Add liblink frontend transport
- Move terminal transport selection into runtime
- Add preconnected frontend transport
- Route stop lifecycle through runtime
- Rebuild projection during reattach
- Move frontend exit lifecycle into runtime
- Move startup attach into runtime
- Route attach state through runtime
- Route transport state through runtime
- Route pane lifecycle through runtime
- Remove frontend-authored detach snapshots
- Move reattach results into runtime
- Move snapshot parsing into runtime
- Introduce shared session projection
- Introduce frontend runtime ownership

### Frontend

- Stop mutating projection during rebuild
- Apply parsed session snapshots
- Rename multiplexer tree to terminal
- Extract terminal view state
- Drop navigation mirrors from state
- Rename ses client boundary
- Share local transport helpers
- Parameterize mux transport startup
- Share attach lifecycle helpers
- Extract shared attach state
- Move pane metadata into shared cache
- Apply matching snapshots incrementally
- Move navigation state into cache
- Move tab metadata into session cache
- Extract session cache from terminal state
- Extract shared session client

### Mux

- Require ses-backed panes

### Runtime

- Hide projection behind frontend runtime
- Own session identity and focus
- Own tab projection helpers

### Ses

- Add canonical session snapshots

### Session

- Drop legacy tab layout sync
- Command live split mutations
- Publish snapshots after command mutations
- Remove dead whole-state sync path
- Apply layouts through ses snapshots
- Drop legacy mux state cache
- Command split layout mutations
- Command tab and float mutations
- Move focus authority into ses
- Reattach from canonical snapshots

### Terminal

- Key split views by pane uuid
- Move float ui state out of pane
- Move pane float metadata into projection
- Rename leftover mux terminology
- Drop dead snapshot sync code
- Route pane metadata queries through projection
- Move pane cwd cache into projection
- Move pane exit status into projection
- Use runtime for list mode
- Route projection through runtime
- Drop raw client state references
- Move layout pane creation into runtime

## [0.0.16] - 2026-03-04

### <!-- 0 -->⛰️  Features

- Add support for multiple border title segments
- Improve floating window title rendering
- Enhance Lua scripting with new APIs and syntax
- Add Lua function support for statusbar click actions

## [0.0.15] - 2026-03-02

### <!-- 0 -->⛰️  Features

- Improve segment parsing error messages
- Improve configuration error messages for segments
- Add ctx.pane last selector
- Add cached Lua command helper and validation
- Introduce Lua event system and tracing for callbacks
- Support styling prefix/suffix for segments
- Enhance Lua context with comprehensive pane API
- Improve Lua `when` condition context for panes
- Introduce function-based keybinding `when` conditions
- Streamline Lua callback evaluation
- Update segment module references and parsing
- Improve Lua builtin evaluation in render modules
- Improve Lua callback handling for prompt segments
- Add segment builtin descriptor constructors
- Enhance statusbar buttons with customizable click states
- Refine prompt segment handling
- Extract segment rendering logic
- Refactor prompt and statusbar to use Lua-first segment model
- Support spinner and randomdo through builtin descriptors
- Add builtin descriptor styling and runtime resolution
- Support builtin Lua source functions in segment runtime
- Infer button segments and require button kind for hover/click
- Infer segment type from value/builtin/button/progress fields
- Add progress segment gating and cadence controls
- Add typed segment kinds and builtin command source
- Improve Lua segment output and styling capabilities
- Add built-in segment functionality via Lua API
- Refactor segment value handling and cleanup 'when' conditions
- Add tests for AsciicastWriter
- Extend `hexe record` to support multiplexer
- Add `mux record` command for recording asciicasts
- Refactor segment value parsing to use 'value' field
- Extend keybinding when conditions with more options
- Implement `hexe record` CLI for recording session control
- Add active button state for status bar segments
- Add hx.record command helpers for Lua config
- Add clickable statusbar segment actions
- Add non-intrusive pod record observer mode
- Add dedicated pod record command
- Add pod attach asciicast recording
- Inherit environment variables in floats
- Improve shell prompt and statusbar Lua support
- Allow reattaching to attached sessions
- Refactor module rendering into dedicated file
- Handle environment inheritance for new panes
- Store cursor state for float completion to restore
- Add liblink dependency to build system
- Implement session manager with .hexe.lua configs
- Refine directional focus navigation
- Refactor mux and ses VT client handling and logging
- Improve dead split handling in main loop
- Improve VT reconnection and backlog replay

### <!-- 1 -->🐛 Bug Fixes

- Stabilize Lua callback rendering in status UI
- Apply block style correctly to status bar segments
- Improve spinner and module rendering
- Fallback to text spinner when animation segments are empty
- Prioritize builtin descriptor colors over builtin defaults
- Treat builtin Lua callbacks as builtin segment source
- Parse button/progress sources before segment validation
- Improve handling of exited processes and panes
- Handle unresponsive float panes
- Correctly read pane_info response
- Trigger backlog replay on pane re-adoption
- Prevent stale CSI/OSC replies from monopolizing routing
- Preserve sticky panes on normal exit
- Enhance sticky float logic for adoption and takeover
- Forward OSC and CSI responses to terminal
- Update xev timer re-arming due to io_uring bug
- Correctly restore cursor position after float
- Align pane exit handling and VT routing
- Retain backlog after replay
- Improve pty/client watcher reliability and logging

### <!-- 2 -->🚜 Refactor

- [**breaking**] Remove legacy Lua callback compatibility
- Remove prefixed lua/builtin command encoding

### <!-- 3 -->📚 Documentation

- Clarify prompt and statusbar Lua usage
- Document pod asciicast recording commands

### <!-- 7 -->⚙️ Miscellaneous Tasks

- Refactor Powerline segment prefixes/suffixes
- Update Lua 'when' definition to reflect callback
- Refactor shell prompt segment values to functions
- Refactor config to use Lua functions for segments
- Refactor shellprompt segments to use Lua
- Rename module directories for clarity
- Add Hexel configuration file
- SEGTERM and improve debug logging timestamp precision

## [0.0.14] - 2026-02-23

### <!-- 1 -->🐛 Bug Fixes

- Improve session detachment and error handling

### <!-- 2 -->🚜 Refactor

- Rename voidbox to libvoid everywhere

## [0.0.13] - 2026-02-22

### <!-- 1 -->🐛 Bug Fixes

- Make float query reply handling deterministic

## [0.0.12] - 2026-02-22

### <!-- 1 -->🐛 Bug Fixes

- Stabilize terminal query routing for float panes
- Route CSI query replies back to panes
- Improve terminal query handling and OSC parsing
- Restore terminal key forwarding in mux
- Add minimal CPR query handling for pane apps
- Harvest pending OSC query targets before stdin routing
- Reliably route OSC color query replies per pane

## [0.0.11] - 2026-02-21

### <!-- 0 -->⛰️  Features

- Add basic CLI help output
- Refactor popup handlers into dedicated module
- Migrate CLI argument parsing to Yazap

## [0.0.10] - 2026-02-21

### <!-- 7 -->⚙️ Miscellaneous Tasks

- Update Linux runners to Ubuntu 24.04

## [0.0.9] - 2026-02-21

### <!-- 7 -->⚙️ Miscellaneous Tasks

- Update dependencies and release workflow

## [0.0.8] - 2026-02-21

### <!-- 7 -->⚙️ Miscellaneous Tasks

- Remove local tag before Zig setup

## [0.0.7] - 2026-02-21

### <!-- 7 -->⚙️ Miscellaneous Tasks

- Trigger release workflow on new release

## [0.0.6] - 2026-02-21

### <!-- 0 -->⛰️  Features

- Map virtual kitty placements with clip offsets
- Prefer unicode width method with explicit-width support
- Render pinned kitty graphics placements
- Bridge kitty image placements into vaxis cells
- Reset mouse shape on mux teardown
- Map OSC8 hyperlinks into vaxis cell links
- Reset mouse shape on mouse-leave events
- Add vaxis-backed clipboard copy action
- Add vaxis-backed system notification action
- Add vaxis-backed system clipboard request action
- Handle in-band winsize and color-scheme updates
- Use vaxis OSC52 clipboard for mux selections
- Integrate vaxis mouse shape transitions
- Add terminal capability diagnostics action
- Apply capability-gated terminal feature modes
- Wire vaxis terminal capability detection cycle
- Parse key events through vaxis parser
- Start vaxis parser integration for input events
- Replace renderer output with libvaxis render engine
- Add ghostty-to-vaxis cell bridge (vt_bridge.zig)

### <!-- 1 -->🐛 Bug Fixes

- Always reset in-band resize mode on exit
- Detect kitty image content changes by hash
- Preserve grapheme text and links across wide cells
- Free cached kitty images on pane teardown
- Hide kitty graphics placeholder glyphs
- Queue OSC query replies per pane
- Forward bracketed paste boundary sequences
- Harden bracketed paste handling across modal paths
- Forward bracketed paste payloads to focused pane
- Keep terminal caps notification message owned
- Expose terminal caps action in Lua API
- Consume unmapped parser events in input dispatch
- Consume parser release/report events before forwarding
- Swallow mid-stream terminal probe replies
- Clamp float and segment numeric fields from lua
- Encode enter and control keys via ghostty mapping
- Parse spinner options in mux add_segment API
- Swallow title clicks during float rename mode
- Unify float title geometry for draw and hit-test
- Sanitize float labels and unstick spinner fallback
- Strip ansi escape payloads from float labels
- Preserve shifted parser text in pane forwarding
- Forward parser text codepoints for char keys
- Filter terminal probe replies from pane input
- Restore float label fallback and generic spinner modules
- Strengthen spinner output and float title rendering
- Restore float exit key, spinner fallback, and title clipping
- Restore float binds, spinner fallback, and tab display mapping
- Swallow modifier-only kitty key transport events
- Swallow parser control sequences before pane forwarding
- Filter terminal capability reply noise on startup
- Enable kitty key timing only after release observed
- Add ctrl-alt fallback for parser key events
- Request full kitty keyboard reporting flags
- Gate parser keybind mode on kitty capability
- Normalize vaxis key events for bind matching
- Restore legacy key dispatch for keybind compatibility
- Restore legacy sgr mouse parser semantics
- Restore legacy mouse mode for float interactions
- Make float title editor unicode-aware
- Make overlay text rendering unicode-aware
- Render popup text with unicode-aware widths
- Preserve utf-8 literals in status formats
- Render float border titles with unicode width
- Use unicode width for statusbar layout and draw
- Add frame arena for non-ASCII grapheme encoding in vaxis bridge

### <!-- 2 -->🚜 Refactor

- Unify terminal resize handling for winsize events
- Track and log detected terminal capabilities
- Add deterministic terminal capability query lifecycle
- Remove OSC compatibility interception path
- Forward OSC queries to terminal without synthetic replies
- Remove pane-side CSI/DCS query emulation
- Simplify parser-only input and feature setup
- Move terminal mode setup fully to vaxis
- Remove remaining raw input fallbacks
- Simplify raw keycast fallback parser
- Prefer parser events for keycast formatting
- Unify raw query-reply stripping helpers
- Return first parsed non-query event directly
- Cache first parsed event after query stripping
- Extract parser-driven input subloops
- Fold parser flag updates into event dispatch
- Reuse first parsed event in input loop
- Prefer parser events for query-reply stripping
- Drop unused key event consumed metadata
- Unify parser-driven pane select and popup dispatch
- Split key event state machine handlers
- Extract popup and rename handlers from input loop
- Clarify osc copy terminator comment
- Reuse parser head helper in input loop
- Remove dead loop input imports
- Avoid reparsing encoded key forwarding bytes
- Simplify blocked popup helper signature
- Thread parsed events into pane forwarding
- Simplify parser-event popup blocking helpers
- Remove debug trace logging from api bridge
- Remove raw-byte float exit key matching
- Remove raw popup byte parser path
- Require parsed events for blocked popup handling
- Remove compatibility key mode and always use full events
- Rename key event mode away from legacy wording
- Route mux popup blocking through parsed event helper
- Replace legacy key encoding with ghostty encoder
- Extract unified parsed event dispatcher
- Centralize parsed non-key event consumption
- Centralize parsed key dispatch in input loop
- Simplify tab popup parsed-event gating
- Unify focused pane popup and forwarding path
- Avoid reparsing popup bytes when event already parsed
- Reuse parser events across blocked popup handlers
- Reuse parsed events for pane popup input
- Reuse parsed popup events in tab popup mode
- Handle mouse input directly as vaxis events
- Simplify parser mouse event conversion
- Dispatch mux input from single parser pass
- Remove obsolete scroll parse wrapper
- Derive scroll actions from parsed vaxis events
- Expose vaxis event helpers for key and scroll
- Remove pooled surface layer from borders
- Trim unused vaxis surface helpers
- Draw split borders directly on renderer
- Move surface threadlocal cleanup into main
- Print statusbar text directly with vaxis window
- Remove remaining float title draw shim
- Drop draw shim in borders and statusbar clear
- Remove popup vaxis draw shim usage
- Move popup overlay and notifications to direct vaxis draws
- Draw statusbar text directly on vaxis row
- Route parser transport and mouse handling through loop input
- Inline frame and pane render orchestration
- Parse mux input in single vaxis pass
- Route parser transport and mouse handling through loop input
- Inline frame and pane render orchestration
- Remove vaxis surface shims and fix parser text forwarding
- Remove vaxis color adapter and use core style colors
- Remove remaining render type bridges and style adapters
- Drop unused style-color conversion in render types
- Remove legacy render Cell compatibility types
- Remove render cell bridge and legacy setCell API
- Route remaining ui primitives through vaxis cell writes
- Render sprite overlay using vaxis cells
- Operate overlay and selection on vaxis cells
- Blit vaxis cells directly into renderer
- Remove CellBuffer path and render directly with vaxis
- Remove render facade module and stale references
- Remove render facade imports across mux modules
- Migrate ui modules to shared render color type
- Hide direct next-buffer access behind renderer api
- Turn render module into facade
- Decouple style and cell helpers from render module
- Extract vaxis frame lifecycle helpers
- Extract render-state blit from renderer core
- Extract render cell and buffer types
- Extract render-to-vaxis bridge helpers
- Split sprite rendering out of render core
- Add core style conversions for vaxis
- Remove legacy pane-input sanitization layer
- Handle ctrl-q quit through parser key path
- Use parser key events for tab-popup tab switching
- Parse popup keys through vaxis parser
- Remove legacy escape-sequence key compatibility path
- Decode mouse events through vaxis parser
- Route statusbar text through pooled vaxis window
- Share render-to-shp style conversion helpers
- Pool temporary vaxis surfaces across modules
- Add shared unicode screen initialization helper
- Share temporary vaxis screen blit helpers
- Centralize grapheme width clipping helper
- Dedupe vaxis cell conversion helpers
- Route split border cells through vaxis window
- Switch mux mouse mode setup to vaxis api
- Render floating border frame via vaxis
- Draw popup frames using vaxis window borders
- Preserve colors in overlay dim effect
- Render notifications via vaxis print
- Render statusbar text via vaxis print
- Remove legacy csi-u input module
- Route paste and mouse parsing through vaxis
- Use vaxis helpers for terminal mode setup
- Remove winpulse feature entirely

### <!-- 3 -->📚 Documentation

- Update keybinding documentation
- Update and expand documentation for Hexa

### <!-- 7 -->⚙️ Miscellaneous Tasks

- Refactor release workflow to use dedicated jobs
- Remove stale input migration comment

### Build

- Require libvaxis and drop caps diagnostics action
- Add libvaxis dependency to mux module

## [0.0.4] - 2026-02-20

### <!-- 0 -->⛰️  Features

- Refactor notification management
- Extract session reattachment logic into a dedicated module
- Close extra file descriptors in child process
- Implement synchronous pane info snapshot
- Migrate I/O handling to xev event loop
- Remove poll-based wait from main loop
- Migrate local float PTY reads to xev watchers
- Migrate local split PTY reads to xev watchers
- Migrate stdin input handling to xev watcher
- Move SES VT and CTL reads to xev watchers
- Move pane sync and heartbeat to xev timer
- Add libxev loop skeleton to runtime
- Remove poll scaffolding from event loop runtime
- Migrate VT routing fds to xev watchers
- Process binary control fds with xev watchers
- Move periodic maintenance to xev timer
- Move server accept path to libxev
- Migrate client IO loop to libxev
- Move PTY drain path to libxev callbacks
- Drive metadata and uplink ticks with xev timer
- Add libxev accept loop and split uplink logic
- Consolidate Voidbox integration and define isolation profiles
- Implement isolation profile for float panes
- Implement voidbox isolation for panes
- Integrate voidbox for process sandboxing

### <!-- 1 -->🐛 Bug Fixes

- Prevent stale ses socket inheritance and add cli socket timeouts
- Remove aggressive reattach pruning and reorder replay registration
- Prune dead layout nodes during session reattach
- Harden reattach tab restore against missing splits and root
- Validate shell event numeric ranges before casting
- Validate mux float isolation profile values
- Clear stale pane metadata caches during reattach reset
- Avoid mutating float list during toggle iteration
- Enforce strict UUID parsing in pop command handlers
- Enforce max frame length in pod frame writer
- Validate pane info trailing payload bounds
- Remove assume-capacity appends in reattach tracking reset
- Safely reject unknown pod frame types
- Accept supported protocol version range in handshakes
- Enforce strict 32-hex UUID parsing in com commands
- Escape layout JSON serializer strings correctly
- Preserve 64-bit tab visibility on reattach
- Free pane osc and exit key allocations on deinit
- Reinitialize osc buffer after pane respawn deinit
- Lazy remove stale watcher nodes to prevent UAF
- Correct config file path in validation and messages
- Handle invalid UUID in pod kill command
- Decode percent-encoded pod metadata fields
- Update SES handshake and CLI message types
- Improve JSON string serialization and config handling
- Guard local watcher removals against fd reuse
- Guard queued closes against fd reuse races
- Disarm client watchers before removing sessions
- Keep xev accept responsive during poll cycles
- Prevent duplicate client watchers from piling up

### <!-- 2 -->🚜 Refactor

- Centralize popup target routing in mux ipc handlers
- Remove unused pane env pair builder
- Remove dead stale-fd watcher scans in mux loop
- Share key modifier translation across mux input paths
- Make popup renderer dimensions derive from config style
- Unify dead float cleanup handling in mux loop
- Standardize and improve config loading
- Move widget logic to new overlay modules
- Modularize mux input and output logic
- Extract poll fd registry reconciliation

### <!-- 3 -->📚 Documentation

- Clarify additive float attribute default merge behavior
- Align sprite keybinding examples with supported bind events
- Add write-meta option to pod daemon help
- Remove unsupported uuid flag from mux float help
- Isolate and clarify isolation documentation
- Update isolation documentation with voidbox profiles

### <!-- 7 -->⚙️ Miscellaneous Tasks

- Refactor pod target resolution into shared module
- Extract keybind action dispatch logic
- Replace debug prints with structured logs
- Remove debug logging from mux module
- Refactor wait timeout logic for write operations
- Update voidbox dependency to use URL and hash

## [0.0.3] - 2026-02-15

### <!-- 0 -->⛰️  Features

- Enhance Lua API for extended configuration
- Implement 'when' condition parsing for keybindings
- Implement new config setup and keymap API
- Use ConfigBuilder for module config
- Wire popup/overlay APIs to Lua hexe.pop module
- Add notification/dialog/widget parsing and C API functions
- Wire prompt APIs to Lua hexe.shp.prompt module
- Add segment parsing helpers and prompt C API functions
- Wire SES C API functions to Lua module
- Implement hexe.ses.session.setup() C API
- Implement hexe.ses.layout.define() C API
- Add recursive layout parsing helpers for panes and splits
- Wire all MUX C API functions to Lua module
- Implement tabs.add_segment, tabs.set_status, splits.setup C APIs
- Implement hexe.mux.float.define() C API
- Implement hexe.mux.float.set_defaults() C API
- Implement hexe.mux.keymap.set() C API
- Add action parsing helpers for simple and parametric actions
- Add key parsing helpers for unified key format
- Implement hexe.mux.config.setup() C API
- Implement hexe.mux.config.set() C API
- Inject hexe.mux/ses/shp/pop/autocmd/api/plugin module structure
- Integrate ConfigBuilder into LuaRuntime
- Add api_bridge skeleton with builder registry helpers
- Add PopConfigBuilder with notification/dialog/widgets config
- Add ShpConfigBuilder with left/right segments
- Add SesConfigBuilder with layouts list
- Add MuxConfigBuilder with full field set
- Add ConfigBuilder skeleton with section builders
- Enable `config validate` and `ses export` commands
- Introduce config validation, SES stats, and resource limits
- Implement session recovery and robust reattach
- Optimize wide character rendering
- Render non-space characters in tmux cells
- Improve CSI-u handling and scrollback
- Introduce widgets module for interactive overlays
- Implement Winpulse animation for focused panes
- Introduce support for Pokemon sprites
- Pokemon sprites
- Remove blocking read for backlog replay
- Implement layout saving and loading
- Support floating panes within a session
- Enhance keybinds with modes and improve float handling
- Enhance float pane usability and input experience
- Refactor mux input handling and IPC
- Refactor keybinding timing and introduce robust tap/repeat logic
- Improve session management and reattach reliability
- Improve cursor handling and CWD resolution
- Enhance float navigation and CWD handling
- Improve time segment and mux focus navigation
- Enhance keybind configuration and behavior
- Implement configurable exit key for floating panes
- Improve keybind handling with tap/hold and deferral
- Refactor keybind handling for Kitty keyboard protocol
- Support default float attributes
- Add float sizing, positioning, and focus mode
- Add `ses kill` and `ses clear` commands
- Add `env` and `env_not` conditions
- Add pod_name segment
- Improve float handling and layout updates
- Allow local config files and new keybind actions
- Implement local .hexe.lua config merging
- Customize mouse selection color
- Implement session layouts and float definitions
- Enhance mouse click behavior and session management
- Update ghostty dependency and optimize pane swap
- Add pane swapping functionality to pane select mode
- Implement overlay system for UI feedback
- Add JSON output for `ses list` and `pod list`
- Refactor mouse events to forward raw SGR to applications
- Optimize mux loop dead pane tracking
- Reimplement state persistence and reattach logic
- Implement versioned handshakes
- Implement SES client heartbeat
- Refactor CLI and core for improved efficiency
- Improve robustness by adding error logging
- Extract string sanitization into separate module
- Implement a centralized logging system
- Centralize and refactor UUID and float utilities
- Implement Unix socket credential verification
- Refactor config and query for unified 'when' conditions
- Relocate spinner rendering to core animations
- Refactor shared components into core module
- Improve floating pane lifecycle management
- Non-blocking CTL channel and rewrite architecture docs
- Skip polling panes without file descriptors
- Improve pane lifecycle management
- Improve pane info request handling
- Refactor Pod and client communication
- Implement binary wire protocol for MUX-SES communication
- Implement new binary communication protocols
- Send and receive pod metadata from the pod
- Implement SHP to POD direct communication
- Improve detached session persistence and reattach
- Add pod cli commands for management
- Always refresh VT render state on output
- Refactor config loading and improve performance
- Add mouse-driven float pane management
- Add `randomdo` module for dynamic status text
- Add randomdo segment
- Add explicit `when` configuration for status modules
- Document conditional `when` for modules
- Add configurable "when" conditions for status modules
- Implement multi-click selection for mouse
- Trim mouse selection to exclude trailing whitespace
- Add mouse selection auto-scroll and improve copy
- Update mouse selection to use buffer coordinates
- Refactor animated status bar checks
- Implement mux-side mouse selection with copy
- Configure Ghostty scrollback size
- Refactor shell init scripts into separate modules
- Introduce multi-instance support and Lua config improvements
- Add programmatic focus movement and program-specific keybindings
- Move `info` command from `ses` to `mux`
- Refactor `com` subcommand into `ses` and `shp`
- Add Lua configuration for mux, pop, and shp
- Refactor key input handling for cleanliness and robustness
- Sanitize and translate kitty keyboard input
- Add sandboxing and resource isolation for panes
- Add support for resizing split panes
- Improve keybind arbitration logic
- Improve and unify focus navigation
- Implement advanced keybinding infrastructure
- Add initial support for Kitty Keyboard Protocol
- Refactor keybinding configuration
- Enhance float configuration and styling
- Improve `com list` output with tree view and colors
- Enhance shell integration with command info and exit intent
- Remove built-in floating window title rendering
- Add support for custom float pane titles
- BIGGGGGGGER FIX
- Improve mouse event handling to respect alt-screen
- Improve tab switching and mouse support
- SUPER FIXXXXXX
- Improve PTY child process reaping and client handling
- Introduce float attributes and new config structure
- Refactor mux into modular files
- Remove unnecessary stdout capture
- Add option to redirect float pane selection to a file
- Streamline and enhance float pane functionality
- Implement blocking float panes
- Enhance pane info with layout, size, and TTY
- Add base and active process info to `com info`
- Implement ad-hoc floating panes via CLI
- Add timeout for handshake during pod spawn
- Optimize pod protocol reader memory allocation
- Increase maximum frame length and add frame skipping
- Use spawn-safe CWD for pod panes
- Allow respawning remote panes
- Add logging capabilities to core components
- Rename project from Hexa to Hexe
- Add initial configuration files for Hexa
- Enable sending input to panes via CLI
- Improve ses daemon allocator handling and logging
- Enhance CWD tracking for pod panes
- README
- REINIT

### <!-- 1 -->🐛 Bug Fixes

- Parse mode as string not number in array format keybindings
- Support passthrough_only bindings without action in array format
- Migrate SesConfig to ConfigBuilder API, ensure all modules use defaults on error
- Migrate PopConfig to ConfigBuilder API, resolve IOT abort
- Prevent segfault by storing stable ConfigBuilder pointer
- Handle wide characters during rendering
- Update selectWord call for ghostty
- Update ghostty dependency hash

### <!-- 3 -->📚 Documentation

- Fix architecture diagrams with box-drawing characters
- Update float pane documentation and add build info

### <!-- 6 -->🧪 Testing

- Add Phase 5 POP API integration test
- Add Phase 4 SHP API integration test
- Add Phase 3 SES API integration test
- Add Phase 2 MUX API integration test
- Add Phase 1 infrastructure verification test

### <!-- 7 -->⚙️ Miscellaneous Tasks

- Remove double pokemon sprites
- Remove double pokemon sprites
- Improve keycast and mux new behavior
- Update project version and dependencies
- VERSION RESET
- Update release workflow and dependencies
- Pass GITHUB_REF for release builds
- Update project version
- Bump version to 0.1.4
- Add manual workflow_dispatch trigger
- Fetch full history for release tags
- Bump version to 0.1.3
- Bump version to 0.1.2
- Bump version to 0.1.1
- Add GitHub Release workflow for binaries
- Remove Kitty Keyboard Protocol documentation

### <!-- 9 -->◀️ Revert

- Disable perf caches causing freeze

