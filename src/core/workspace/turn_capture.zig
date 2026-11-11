//! A turn's workspace captures, while `experimental.workspace_capture` is
//! on: the repository holding the session's folder, at the turn's start and
//! end, and each other repository a tool acts in, saved as the session's
//! `workspace_capture` items (D98).
//!
//! A host keeps one `TurnCapture` per session. `begin` runs where the turn
//! starts, beside the prompt's images, then the host saves the user's
//! prompt, then `start` takes the start capture, all before the first
//! request. `end` runs on the turn's thread before the turn's commit, which
//! uses `token`. A failed commit keeps both the token and the end capture,
//! so a retry of the same turn writes each once; `committed` ends the turn
//! once a commit lands. A capture that fails, times out, or finds no
//! repository still records what happened, and nothing here ever fails the
//! turn.
//!
//! A tool that reaches a repository whose worktree root is `/`, the home
//! folder, or an ancestor of it captures nothing, so a home folder kept as
//! a dotfiles repository never enters fx's store; the trace records the
//! skip (`isPrivateRoot`).
const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const capture_store = @import("capture_store.zig");
const capture_retention = @import("capture_retention.zig");
const session_adapter = @import("../session/session_adapter.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const repo_root = @import("repo_root.zig");

const Allocator = std.mem.Allocator;
const Session = session_adapter.Session;

/// Whether this build can capture: it needs processes for git and threads
/// for the indexer, which the libfx WebAssembly builds do not have. Hosts
/// leave the start hook unset and skip the end capture when it is false.
pub const supported = !builtin.single_threaded and switch (builtin.target.os.tag) {
    .wasi, .freestanding => false,
    else => true,
};

/// One budget for a whole capture, every git run included, so a slow
/// repository delays the turn by at most this much.
pub const deadline_ms: i64 = 2000;

/// Bounds measuring the captures folder and, when it is over the budget,
/// maintenance. Maintenance runs at most every
/// `capture_retention.measure_interval_ms`, so a turn rarely waits for it.
pub const maintenance_deadline_ms: i64 = 30_000;

pub const Context = struct {
    session: *Session,
    /// The home the session store uses; captures go under fx's folder in it,
    /// `~/.fx` or `$FX_HOME` (`profile_paths.rootDir`).
    home: []const u8,
    /// The folder the session works in; its repository is captured.
    path: []const u8,
    /// Thread-safe, for the indexer's folder threads; nothing allocated
    /// with it outlives the call.
    alloc: Allocator,
};

/// Where a host's captures go: the session store's home and the folder whose
/// repository is captured. A subagent run borrows its parent's.
pub const Target = struct {
    home: []const u8,
    path: []const u8,

    pub fn context(target: Target, session: *Session) Context {
        return .{ .session = session, .home = target.home, .path = target.path, .alloc = std.heap.c_allocator };
    }
};

/// Repositories beyond the session's own that one turn captures, so a turn
/// that wanders through many repositories delays its tools a bounded time.
pub const max_reached = 8;

/// Takes, encodes and saves one capture; `record` outside tests.
const Recorder = fn (context: Context, turn: Session.CaptureTurn, phase: capture_store.Phase, lock: *std.Io.Mutex, trigger_tool: ?[]const u8) void;

/// A repository a tool reached, by worktree root. Owned,
/// `std.heap.c_allocator`.
const Reached = struct {
    root: []u8,
    /// Its start capture is running; a parallel call that reaches the same
    /// repository waits on `settled` until it is saved.
    saving: bool,
};

/// One session's turn captures. Hosts call `begin` and `start` on the turn's
/// thread, `reach` from any tool call, possibly in parallel, and `end`,
/// `token` and `committed` from the thread that commits, which in the app is
/// the UI thread for `token` and `committed` only. Every field is read and
/// written under `mutex`, and no capture runs while it is held.
pub const TurnCapture = struct {
    mutex: std.Io.Mutex = .init,
    /// Broadcast whenever a reached repository's start capture is saved.
    settled: std.Io.Condition = .init,
    current: ?Session.CaptureTurn = null,
    /// `begin` ran and the turn's own start capture has not.
    start_pending: bool = false,
    /// Whether this turn's end capture is taken, so a retried commit does
    /// not take a second one.
    ended: bool = false,
    /// The worktree root holding the session's folder, found as the turn
    /// began; null outside a repository. Owned, `std.heap.c_allocator`.
    main_root: ?[]u8 = null,
    /// Other worktree roots the turn's tools reached, each with a start
    /// capture taken before the first action that reached it (D98).
    reached: std.ArrayList(Reached) = .empty,
    /// Bumped whenever the turn's repositories are forgotten, so a reach
    /// that finishes after its turn ended never marks a later turn's entry.
    generation: u64 = 0,
    /// The capture seam for tests; null takes real captures. A default of
    /// `&record` would compile captures into builds that cannot take them.
    recorder: ?*const Recorder = null,

    /// Begins the turn's captures: takes the session's capture token. A
    /// steering message inside a turn already begun (`fresh` false) adds
    /// nothing; a fresh turn always begins anew, so a turn that ended
    /// without its commit never lends its token to the next. The host saves
    /// the user's prompt after this and before `start`, so a kill during the
    /// start capture keeps the prompt.
    pub fn begin(self: *TurnCapture, context: Context, fresh: bool) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (!fresh and self.current != null) return;
        self.forgetLocked();
        self.current = context.session.beginCaptureTurn();
        self.ended = false;
        self.start_pending = true;
    }

    /// Saves the start capture of the turn `begin` began, once.
    pub fn start(self: *TurnCapture, context: Context, lock: *std.Io.Mutex) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        const turn = self.current orelse {
            self.mutex.unlock(io);
            return;
        };
        const pending = self.start_pending;
        self.start_pending = false;
        self.mutex.unlock(io);
        if (!pending) return;
        const root = worktreeRoot(context.path);
        self.mutex.lockUncancelable(io);
        if (self.current == turn and self.main_root == null) {
            self.main_root = root;
        } else if (root) |value| std.heap.c_allocator.free(value);
        self.mutex.unlock(io);
        self.capture(context, turn, .start, lock, null);
    }

    /// A tool is about to act in `dir`: the first action of the turn in a
    /// repository other than the session's takes that repository's start
    /// capture first. `dir` is a command's working folder or the folder of
    /// a file a mutation writes; it may not exist yet. A parallel call that
    /// reaches the same repository waits until that capture is saved; calls
    /// that reach different repositories capture at once. A repository at
    /// the filesystem root, at the home folder, or above it is never
    /// captured (`isPrivateRoot`).
    pub fn reach(self: *TurnCapture, context: Context, dir: []const u8, tool: []const u8, lock: *std.Io.Mutex) void {
        const io = io_mod.getIo();
        const root = worktreeRoot(dir) orelse return;
        defer std.heap.c_allocator.free(root);
        const private = isPrivateRoot(root, &.{ io_mod.getenv("HOME"), context.home });
        self.mutex.lockUncancelable(io);
        const Claim = struct { turn: Session.CaptureTurn, generation: u64 };
        const claim: ?Claim = while (true) {
            const turn = self.current orelse break null;
            if (self.ended) break null;
            if (self.main_root) |main| if (std.mem.eql(u8, main, root)) break null;
            if (self.findLocked(root)) |known| {
                if (!known.saving) break null;
                self.settled.waitUncancelable(io, &self.mutex);
                continue;
            }
            if (private) {
                debug_trace.logf("workspace", "event=workspace_capture_reach_skipped session={s} tool={s} reason=private_root", .{ context.session.id(), tool });
                break null;
            }
            if (self.reached.items.len >= max_reached) {
                debug_trace.logf("workspace", "event=workspace_capture_reach_skipped session={s} tool={s} reason=limit", .{ context.session.id(), tool });
                break null;
            }
            const owned = std.heap.c_allocator.dupe(u8, root) catch break null;
            self.reached.append(std.heap.c_allocator, .{ .root = owned, .saving = true }) catch {
                std.heap.c_allocator.free(owned);
                break null;
            };
            break .{ .turn = turn, .generation = self.generation };
        };
        self.mutex.unlock(io);
        const claimed = claim orelse return;
        var reached_context = context;
        reached_context.path = root;
        self.capture(reached_context, claimed.turn, .start, lock, tool);
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.generation == claimed.generation) {
            if (self.findLocked(root)) |known| known.saving = false;
        }
        self.settled.broadcast(io);
    }

    /// Saves the end capture once per turn, held for the commit that uses
    /// the token. Runs on the turn's thread: in the app, as the turn
    /// finishes and before its finished prompt reaches the UI, so the UI's
    /// commit only writes what is held.
    pub fn end(self: *TurnCapture, context: Context, lock: *std.Io.Mutex) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        const turn = self.current orelse {
            self.mutex.unlock(io);
            return;
        };
        if (self.ended) {
            self.mutex.unlock(io);
            return;
        }
        // A reached repository's start capture comes before its end.
        while (self.anySavingLocked()) self.settled.waitUncancelable(io, &self.mutex);
        self.ended = true;
        var roots: std.ArrayList([]u8) = .empty;
        defer {
            for (roots.items) |root| std.heap.c_allocator.free(root);
            roots.deinit(std.heap.c_allocator);
        }
        for (self.reached.items) |known| {
            const copy = std.heap.c_allocator.dupe(u8, known.root) catch continue;
            roots.append(std.heap.c_allocator, copy) catch std.heap.c_allocator.free(copy);
        }
        self.mutex.unlock(io);
        debug_trace.logf("workspace", "event=workspace_capture_end session={s} reached={d} thread={d}", .{ context.session.id(), roots.items.len, std.Thread.getCurrentId() });
        self.capture(context, turn, .end, lock, null);
        for (roots.items) |root| {
            var reached_context = context;
            reached_context.path = root;
            self.capture(reached_context, turn, .end, lock, null);
        }
    }

    /// The token the turn's commit uses: the turn whose end capture is
    /// taken. Null when no turn began, or when it has not ended yet, as
    /// when the next turn has already begun on the turn's thread while the
    /// app's UI still commits the one before; that commit then takes no
    /// captures, which the session would have dropped anyway (D98).
    pub fn token(self: *TurnCapture) ?Session.CaptureTurn {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return if (self.ended) self.current else null;
    }

    /// The commit that used `used`, from `token`, landed: its captures are
    /// written. A commit that used no token, or one no longer current,
    /// changes nothing.
    pub fn committed(self: *TurnCapture, used: ?Session.CaptureTurn) void {
        const turn = used orelse return;
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.current != turn) return;
        self.current = null;
        self.ended = false;
        self.start_pending = false;
        self.forgetLocked();
    }

    /// Frees what the turn's repositories hold. The owner calls it once no
    /// thread uses the captures.
    pub fn deinit(self: *TurnCapture) void {
        self.forgetLocked();
        self.reached.deinit(std.heap.c_allocator);
        self.* = .{};
    }

    fn capture(self: *const TurnCapture, context: Context, turn: Session.CaptureTurn, phase: capture_store.Phase, lock: *std.Io.Mutex, trigger_tool: ?[]const u8) void {
        (self.recorder orelse &record)(context, turn, phase, lock, trigger_tool);
    }

    fn findLocked(self: *TurnCapture, root: []const u8) ?*Reached {
        for (self.reached.items) |*known| if (std.mem.eql(u8, known.root, root)) return known;
        return null;
    }

    fn anySavingLocked(self: *const TurnCapture) bool {
        for (self.reached.items) |known| if (known.saving) return true;
        return false;
    }

    fn forgetLocked(self: *TurnCapture) void {
        if (self.main_root) |root| std.heap.c_allocator.free(root);
        self.main_root = null;
        for (self.reached.items) |known| std.heap.c_allocator.free(known.root);
        self.reached.clearRetainingCapacity();
        self.generation +%= 1;
        // A reach waiting on a forgotten repository looks again and finds
        // its turn over.
        self.settled.broadcast(io_mod.getIo());
    }
};

/// Whether a repository at `root` is never captured when a tool reaches it:
/// the filesystem root, or a root that is one of `homes` or an ancestor of
/// one, such as a home folder kept as a dotfiles repository. Each home is
/// compared by its real path; an unset or unresolvable one is skipped.
fn isPrivateRoot(root: []const u8, homes: []const ?[]const u8) bool {
    if (std.mem.eql(u8, std.mem.trimEnd(u8, root, "/"), "")) return true;
    for (homes) |maybe| {
        const home = maybe orelse continue;
        if (home.len == 0) continue;
        const real = io_mod.realpathAlloc(std.heap.c_allocator, home) catch continue;
        defer std.heap.c_allocator.free(real);
        if (isSameOrAncestor(root, real)) return true;
    }
    return false;
}

fn isSameOrAncestor(ancestor: []const u8, path: []const u8) bool {
    const base = std.mem.trimEnd(u8, ancestor, "/");
    if (base.len == 0) return true;
    if (!std.mem.startsWith(u8, path, base)) return false;
    return path.len == base.len or path[base.len] == '/';
}

/// Gives a fork the source's workspace captures, so retention keeps them
/// while the fork's log refers to them (D98): the source session's under the
/// fork's id, and each copied subagent's under its copy's id. Hosts call it
/// for every fork while `experimental.workspace_capture` is on. A failure is
/// traced and the fork stands without those captures.
pub fn copyForkCaptures(home: []const u8, source_id: []const u8, fork: *Session, copies: []const Session.ChildCopy) void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const profile_root = profile_paths.rootDir(arena, home) catch |err| {
        debug_trace.logf("workspace", "event=workspace_capture_fork_refs_failed from={s} to={s} err={s}", .{ source_id, fork.id(), @errorName(err) });
        return;
    };
    copyRefs(arena, profile_root, source_id, fork.id());
    if (copies.len == 0) return;
    const forked = fork.children(arena) catch |err| {
        debug_trace.logf("workspace", "event=workspace_capture_fork_refs_failed from={s} to={s} err={s}", .{ source_id, fork.id(), @errorName(err) });
        return;
    };
    for (copies) |copy| {
        for (forked) |child| if (std.mem.eql(u8, child.work_id, copy.work_id)) {
            copyRefs(arena, profile_root, copy.id, child.id);
            break;
        };
    }
}

fn copyRefs(arena: Allocator, profile_root: []const u8, from: []const u8, to: []const u8) void {
    const copied = capture_store.copySessionRefs(arena, .{
        .profile_root = profile_root,
        .from_session_id = from,
        .to_session_id = to,
        .deadline = .fromNow(io_mod.getIo(), .{ .clock = .awake, .raw = .fromMilliseconds(deadline_ms) }),
    }) catch |err| {
        debug_trace.logf("workspace", "event=workspace_capture_fork_refs_failed from={s} to={s} err={s}", .{ from, to, @errorName(err) });
        return;
    };
    debug_trace.logf("workspace", "event=workspace_capture_fork_refs from={s} to={s} copied={d} existing={d} conflicting={d} failed_stores={d}", .{ from, to, copied.copied, copied.existing, copied.conflicting, copied.failed_stores });
}

/// Captures, encodes and saves one phase. The capture runs without `lock`,
/// the host's session write lock, which only the save takes.
fn record(context: Context, turn: Session.CaptureTurn, phase: capture_store.Phase, lock: *std.Io.Mutex, trigger_tool: ?[]const u8) void {
    const io = io_mod.getIo();
    var arena_state = std.heap.ArenaAllocator.init(context.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const id = context.session.id();
    const profile_root = profile_paths.rootDir(arena, context.home) catch |err| {
        debug_trace.logf("workspace", "event=workspace_capture_skipped session={s} phase={s} err={s}", .{ id, @tagName(phase), @errorName(err) });
        return;
    };
    // Over the space budget, the capture records why and writes nothing.
    const outcome: capture_store.Outcome = if (!admitted(arena, context, profile_root)) .{ .status = .unavailable, .reason = .budget } else capture_store.capture(arena, .{
        .profile_root = profile_root,
        .path = context.path,
        .session_id = id,
        .phase = phase,
        .unix_seconds = @divFloor(io_mod.milliTimestamp(), std.time.ms_per_s),
        .deadline = .fromNow(io, .{ .clock = .awake, .raw = .fromMilliseconds(deadline_ms) }),
        .scan_allocator = context.alloc,
    }) catch |err| {
        debug_trace.logf("workspace", "event=workspace_capture_skipped session={s} phase={s} err={s}", .{ id, @tagName(phase), @errorName(err) });
        return;
    };
    debug_trace.logf("workspace", "event=workspace_capture session={s} phase={s} status={s} reason={s}", .{
        id, @tagName(phase), @tagName(outcome.status), if (outcome.reason) |reason| @tagName(reason) else "none",
    });
    var triggered = outcome;
    triggered.trigger_tool = trigger_tool;
    const payload = capture_store.encodeRecord(arena, phase, triggered) catch |err| {
        debug_trace.logf("workspace", "event=workspace_capture_unsaved session={s} phase={s} err={s}", .{ id, @tagName(phase), @errorName(err) });
        return;
    };
    lock.lockUncancelable(io);
    defer lock.unlock(io);
    _ = context.session.saveWorkspaceCapture(turn, payload, switch (phase) {
        .start => .start,
        .end => .end,
    }) catch |err| {
        debug_trace.logf("workspace", "event=workspace_capture_unsaved session={s} phase={s} err={s}", .{ id, @tagName(phase), @errorName(err) });
    };
}

/// The worktree root holding `dir`, symlinks resolved, by `repo_root.zig`'s
/// rules. Reads names and small metadata files only and never runs git, so
/// a tool's every action can ask. Null outside a repository or for a
/// relative `dir`. Owned, `std.heap.c_allocator`.
fn worktreeRoot(dir: []const u8) ?[]u8 {
    if (!std.Io.Dir.path.isAbsolute(dir)) return null;
    const found = (repo_root.find(std.heap.c_allocator, dir) catch return null) orelse return null;
    defer std.heap.c_allocator.free(found.git_dir);
    return io_mod.realpathAlloc(std.heap.c_allocator, found.root) catch null;
}

/// Whether the profile's captures leave room for this one; runs retention's
/// maintenance when they do not. Any failure here refuses the capture.
fn admitted(arena: Allocator, context: Context, profile_root: []const u8) bool {
    const io = io_mod.getIo();
    const id = context.session.id();
    const key = capture_store.sessionKey(arena, id) catch return false;
    var lookup: SessionLookup = .{ .store = context.session.store, .arena = arena };
    const admission = capture_retention.admit(arena, .{
        .profile_root = profile_root,
        .current_key = key,
        .sessions = lookup.view(),
        .now_ms = io_mod.milliTimestamp(),
        .deadline = .fromNow(io, .{ .clock = .awake, .raw = .fromMilliseconds(maintenance_deadline_ms) }),
    }) catch return false;
    if (admission.maintained or !admission.admit) {
        debug_trace.logf("workspace", "event=workspace_capture_budget session={s} admit={} used={?d} maintained={}", .{ id, admission.admit, admission.used, admission.maintained });
    }
    return admission.admit;
}

/// The profile's sessions by capture key, listed only when maintenance asks.
const SessionLookup = struct {
    store: *session_adapter.Store,
    arena: Allocator,
    ids: std.StringHashMapUnmanaged([]const u8) = .empty,
    loaded: bool = false,
    /// The catalog could not be read: every session counts as present and
    /// open, so nothing is evicted.
    unknown: bool = false,

    fn view(self: *SessionLookup) capture_retention.Sessions {
        return .{ .ctx = self, .exists = exists, .busy = busy };
    }

    fn load(self: *SessionLookup) void {
        if (self.loaded) return;
        self.loaded = true;
        const ids = self.store.sessionIds(self.arena) orelse {
            self.unknown = true;
            return;
        };
        for (ids) |id| {
            const key = capture_store.sessionKey(self.arena, id) catch {
                self.unknown = true;
                return;
            };
            self.ids.put(self.arena, key, id) catch {
                self.unknown = true;
                return;
            };
        }
    }

    fn exists(ctx: *anyopaque, key: []const u8) bool {
        const self: *SessionLookup = @ptrCast(@alignCast(ctx));
        self.load();
        return self.unknown or self.ids.contains(key);
    }

    fn busy(ctx: *anyopaque, key: []const u8) bool {
        const self: *SessionLookup = @ptrCast(@alignCast(ctx));
        self.load();
        if (self.unknown) return true;
        const id = self.ids.get(key) orelse return false;
        return self.store.sessionBusy(id);
    }
};

/// A session in a temporary home, and repositories beside it, for the
/// tests below.
const TestSession = struct {
    tmp: std.testing.TmpDir,
    home: []u8,
    store: session_adapter.Store,
    session: *Session,
    model: [1]u8 = "m".*,

    fn init(t: *TestSession) !void {
        t.tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer t.tmp.cleanup();
        t.home = try io_mod.dirRealpathAlloc(std.testing.allocator, t.tmp.dir, ".");
        errdefer std.testing.allocator.free(t.home);
        t.store = try session_adapter.Store.open(std.testing.allocator, t.home);
        errdefer t.store.deinit(std.testing.allocator);
        t.model = "m".*;
        t.session = try Session.create(std.testing.allocator, &t.store, "/w", .ask, .{
            .preferences = .{ .model = &t.model, .effort = .auto, .fast_mode = false },
            .language = @import("../shared/types.zig").ConversationLanguage.default(),
            .permission_state = .{},
        });
    }

    fn deinit(t: *TestSession) void {
        t.session.close();
        t.store.deinit(std.testing.allocator);
        std.testing.allocator.free(t.home);
        t.tmp.cleanup();
    }

    /// Makes `<tmp>/<name>` a repository and returns a folder inside it.
    fn repository(t: *TestSession, name: []const u8) ![]u8 {
        var buf: [256]u8 = undefined;
        try t.tmp.dir.createDirPath(std.testing.io, try std.mem.print(&buf, "repos/{s}/.git", .{name}));
        try t.tmp.dir.createDirPath(std.testing.io, try std.mem.print(&buf, "repos/{s}/src", .{name}));
        return std.Io.Dir.path.join(std.testing.allocator, &.{ t.home, "repos", name, "src" });
    }

    /// A context whose home is not above the repositories, so reaching
    /// them is allowed.
    fn context(t: *TestSession) Context {
        return .{ .session = t.session, .home = "/nonexistent-fx-test-home", .path = t.home, .alloc = std.heap.c_allocator };
    }
};

/// What the fake recorder saw; the tests run one at a time.
const FakeRecorder = struct {
    var starts: std.atomic.Value(usize) = .init(0);
    var ends: std.atomic.Value(usize) = .init(0);
    var active: std.atomic.Value(usize) = .init(0);
    var max_active: std.atomic.Value(usize) = .init(0);
    var saved: std.atomic.Value(bool) = .init(false);
    /// Each start capture waits until this many run at once, or 2 s.
    var wait_for: usize = 1;

    fn reset(concurrent: usize) void {
        starts.store(0, .seq_cst);
        ends.store(0, .seq_cst);
        active.store(0, .seq_cst);
        max_active.store(0, .seq_cst);
        saved.store(false, .seq_cst);
        wait_for = concurrent;
    }

    fn record(context: Context, turn: Session.CaptureTurn, phase: capture_store.Phase, lock: *std.Io.Mutex, trigger_tool: ?[]const u8) void {
        _ = .{ context, turn, lock, trigger_tool };
        if (phase == .end) {
            _ = ends.fetchAdd(1, .seq_cst);
            return;
        }
        _ = starts.fetchAdd(1, .seq_cst);
        const now = active.fetchAdd(1, .seq_cst) + 1;
        _ = max_active.fetchMax(now, .seq_cst);
        var waited: usize = 0;
        while (active.load(.seq_cst) < wait_for and waited < 2000) : (waited += 1) io_mod.sleep(std.time.ns_per_ms);
        saved.store(true, .seq_cst);
        _ = active.fetchSub(1, .seq_cst);
    }
};

fn reachIn(captures: *TurnCapture, context: Context, dir: []const u8, lock: *std.Io.Mutex) void {
    captures.reach(context, dir, "write_file", lock);
}

test "the worktree root follows the shared finder and resolves symlinks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "repo/.git");
    try tmp.dir.createDirPath(std.testing.io, "repo/src");
    const base = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(base);
    const dir = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "repo/src/new" });
    defer std.testing.allocator.free(dir);
    const got = worktreeRoot(dir).?;
    defer std.heap.c_allocator.free(got);
    const want = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "repo" });
    defer std.testing.allocator.free(want);
    try std.testing.expectEqualStrings(want, got);
    try std.testing.expect(worktreeRoot("relative/path") == null);
}

test "a reached repository at the filesystem root, the home folder, or above it is private" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "users/me/work");
    const base = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(base);
    const home = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "users/me" });
    defer std.testing.allocator.free(home);
    const users = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "users" });
    defer std.testing.allocator.free(users);
    const work = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "users/me/work" });
    defer std.testing.allocator.free(work);
    const sibling = try std.Io.Dir.path.join(std.testing.allocator, &.{ base, "users/meme" });
    defer std.testing.allocator.free(sibling);
    const homes = [_]?[]const u8{ null, home };
    try std.testing.expect(isPrivateRoot("/", &homes));
    try std.testing.expect(isPrivateRoot(home, &homes));
    try std.testing.expect(isPrivateRoot(users, &homes));
    try std.testing.expect(!isPrivateRoot(work, &homes));
    try std.testing.expect(!isPrivateRoot(sibling, &homes));
}

test "reach skips a repository at the home folder and captures one beside it" {
    var t: TestSession = undefined;
    try t.init();
    defer t.deinit();
    FakeRecorder.reset(1);
    var lock: std.Io.Mutex = .init;
    var captures: TurnCapture = .{ .recorder = &FakeRecorder.record };
    defer captures.deinit();
    var context = t.context();
    const home_dir = try t.repository("home");
    defer std.testing.allocator.free(home_dir);
    const other_dir = try t.repository("other");
    defer std.testing.allocator.free(other_dir);
    context.home = std.Io.Dir.path.dirname(home_dir).?;
    captures.begin(context, true);
    captures.reach(context, home_dir, "write_file", &lock);
    try std.testing.expectEqual(@as(usize, 0), FakeRecorder.starts.load(.seq_cst));
    captures.reach(context, other_dir, "write_file", &lock);
    try std.testing.expectEqual(@as(usize, 1), FakeRecorder.starts.load(.seq_cst));
}

test "parallel reaches of different repositories capture at once" {
    var t: TestSession = undefined;
    try t.init();
    defer t.deinit();
    FakeRecorder.reset(2);
    var lock: std.Io.Mutex = .init;
    var captures: TurnCapture = .{ .recorder = &FakeRecorder.record };
    defer captures.deinit();
    const context = t.context();
    const a = try t.repository("a");
    defer std.testing.allocator.free(a);
    const b = try t.repository("b");
    defer std.testing.allocator.free(b);
    captures.begin(context, true);
    const first = try std.Thread.spawn(.{}, reachIn, .{ &captures, context, a, &lock });
    const second = try std.Thread.spawn(.{}, reachIn, .{ &captures, context, b, &lock });
    first.join();
    second.join();
    // Serialized captures would each wait 2 s alone and never overlap.
    try std.testing.expectEqual(@as(usize, 2), FakeRecorder.max_active.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 2), FakeRecorder.starts.load(.seq_cst));
}

test "a parallel reach of the same repository waits for its one start capture" {
    var t: TestSession = undefined;
    try t.init();
    defer t.deinit();
    // Never two at once, so each start capture waits its full 2 s cap,
    // long enough for the second call to arrive while the first runs.
    FakeRecorder.reset(2);
    var lock: std.Io.Mutex = .init;
    var captures: TurnCapture = .{ .recorder = &FakeRecorder.record };
    defer captures.deinit();
    const context = t.context();
    const a = try t.repository("a");
    defer std.testing.allocator.free(a);
    captures.begin(context, true);
    const first = try std.Thread.spawn(.{}, reachIn, .{ &captures, context, a, &lock });
    while (FakeRecorder.starts.load(.seq_cst) == 0) io_mod.sleep(std.time.ns_per_ms);
    captures.reach(context, a, "write_file", &lock);
    // The second call returned only after the start capture was saved.
    try std.testing.expect(FakeRecorder.saved.load(.seq_cst));
    first.join();
    try std.testing.expectEqual(@as(usize, 1), FakeRecorder.starts.load(.seq_cst));
}

test "a reach racing the turn's commit leaves no repository behind" {
    var t: TestSession = undefined;
    try t.init();
    defer t.deinit();
    FakeRecorder.reset(2);
    var lock: std.Io.Mutex = .init;
    var captures: TurnCapture = .{ .recorder = &FakeRecorder.record };
    defer captures.deinit();
    const context = t.context();
    const a = try t.repository("a");
    defer std.testing.allocator.free(a);
    captures.begin(context, true);
    const turn = captures.current;
    const racer = try std.Thread.spawn(.{}, reachIn, .{ &captures, context, a, &lock });
    while (FakeRecorder.starts.load(.seq_cst) == 0) io_mod.sleep(std.time.ns_per_ms);
    captures.committed(turn);
    racer.join();
    try std.testing.expect(captures.current == null);
    try std.testing.expectEqual(@as(usize, 0), captures.reached.items.len);
    // A reach after the commit has no turn to capture for.
    captures.reach(context, a, "write_file", &lock);
    try std.testing.expectEqual(@as(usize, 1), FakeRecorder.starts.load(.seq_cst));
}

test "a turn captures at most max_reached other repositories, and its end captures each" {
    var t: TestSession = undefined;
    try t.init();
    defer t.deinit();
    FakeRecorder.reset(1);
    var lock: std.Io.Mutex = .init;
    var captures: TurnCapture = .{ .recorder = &FakeRecorder.record };
    defer captures.deinit();
    const context = t.context();
    captures.begin(context, true);
    var index: usize = 0;
    while (index < max_reached + 1) : (index += 1) {
        var buf: [16]u8 = undefined;
        const dir = try t.repository(try std.mem.print(&buf, "r{d}", .{index}));
        defer std.testing.allocator.free(dir);
        captures.reach(context, dir, "write_file", &lock);
    }
    try std.testing.expectEqual(@as(usize, max_reached), FakeRecorder.starts.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, max_reached), captures.reached.items.len);
    try std.testing.expect(captures.token() == null);
    captures.end(context, &lock);
    const turn = captures.token();
    try std.testing.expect(turn != null);
    // The session's own repository and each reached one.
    try std.testing.expectEqual(@as(usize, max_reached + 1), FakeRecorder.ends.load(.seq_cst));
    // A retried commit reuses the end capture.
    captures.end(context, &lock);
    try std.testing.expectEqual(@as(usize, max_reached + 1), FakeRecorder.ends.load(.seq_cst));
    captures.committed(turn);
    try std.testing.expect(captures.token() == null);
}
