//! Retention of workspace captures: captures stay while
//! their session exists, within one budget for the whole profile.
//!
//! Before a capture writes, `admit` checks the space `~/.fx/captures` takes.
//! The space is kept per store in `captures/usage`, so a capture walks only
//! the stores that changed:
//!
//! ```text
//! v2 <total bytes> <last maintenance, unix ms or 0>
//! <store folder> <bytes> <measured, unix ms> <fingerprint, 16 hex digits>
//! ```
//!
//! one store line per folder, in name order. The fingerprint hashes the
//! times of the store's object folders: a new loose object changes its
//! fan-out folder's time, a pack the pack folder's. A store is walked again
//! when its fingerprint differs, when its measure is `measure_interval_ms`
//! old, and when it is new; a store that is gone drops out. A fingerprint
//! taken within `racy_ms` of a folder's time is written as zero and never
//! matches, since a later write in the same clock tick would leave the time
//! as it was. The few files beside the stores are counted on every admit.
//! Any other content, such as the one-line format before it, is no cache:
//! every store is walked again. Over the budget, maintenance runs at most
//! once per `measure_interval_ms`:
//!
//! 1. Every store is packed and pruned, which also finishes an eviction a
//!    crash stopped between deleting refs and pruning.
//! 2. Whole sessions are evicted until the space is under the target, 4 of
//!    the 5 GiB, so maintenance does not run every turn:
//!    first sessions that no longer exist, then those captured longest ago.
//!    The current session and sessions another process has open are never
//!    evicted. A chain cannot drop single captures and keep later ones, so a
//!    session goes whole.
//! 3. Each eviction is journaled in `captures/evictions.jsonl`, two synced
//!    lines per session, so a removal is never silent: `"phase":"intent"`
//!    with the refs found, before any ref is deleted, then `"phase":"done"`
//!    with the refs deleted and those `kept` because a capture moved them
//!    meanwhile. An intent without its done line is an eviction a crash
//!    stopped. A session that kept every ref is not reported as evicted.
//! 4. Eviction stops when a store it deleted refs from cannot be pruned or
//!    the space cannot be measured: the space would not be seen to drop, and
//!    evicting on would remove sessions the budget does not need gone.
//!
//! Pruning runs under every capture lock of the store: first the store's
//! `init.lock`, which a capture passes before it writes any object, then
//! each worktree's lock, in name order. No capture of the store is then
//! running, so every unreachable object goes at once. A grace period would
//! not do: git loosens objects from the pack the first prune wrote with that
//! pack's time, so an evicted session's objects would stay an hour and the
//! space would not drop. A capture takes its worktree lock before
//! `init.lock`, the opposite order, but both wait only until a deadline, so
//! neither waits forever; a store still locked at the deadline is left
//! unpruned this time.
//!
//! A worktree's capture index names blobs a prune may remove, and git trusts
//! the index for files that did not change, so a pruned blob could end up in
//! a later tree. Maintenance deletes each index before pruning; the next
//! capture starts it again from the user's index.
//!
//! Captures stop (`unavailable`, reason `budget`) while the space stays over
//! the budget; nothing is deleted beyond whole inactive sessions.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const safe_git = @import("../shell_command/safe_git.zig");
const sort_utils = @import("../shared/sort_utils.zig");
const capture_store = @import("capture_store.zig");

const Allocator = std.mem.Allocator;

pub const budget_bytes: u64 = 5 << 30;
/// Eviction stops under this, so the next maintenance waits for the space
/// to grow by the difference.
pub const target_bytes: u64 = 4 << 30;
pub const measure_interval_ms: i64 = 10 * std.time.ms_per_min;
/// Folder times this close to the clock are too recent to fingerprint: it
/// covers a coarse file clock's tick.
const racy_ms: i64 = 50;

/// What maintenance asks about the profile's sessions, by ref key
/// (`capture_store.sessionKey`).
pub const Sessions = struct {
    ctx: *anyopaque,
    /// Whether a session with this key still exists. When unsure, true.
    exists: *const fn (ctx: *anyopaque, key: []const u8) bool,
    /// Whether another process has the session open. When unsure, true.
    busy: *const fn (ctx: *anyopaque, key: []const u8) bool,
};

pub const Config = struct {
    profile_root: []const u8,
    /// The capturing session's key: never evicted.
    current_key: []const u8,
    sessions: Sessions,
    now_ms: i64,
    /// Bounds measuring and maintenance, every git run included.
    deadline: std.Io.Clock.Timestamp,
    budget: u64 = budget_bytes,
    target: u64 = target_bytes,
};

pub const EvictionReason = enum { orphan, budget };

pub const Eviction = struct {
    key: []const u8,
    reason: EvictionReason,
    /// Refs deleted; a ref a capture moved meanwhile stays.
    refs: usize,
};

pub const Admission = struct {
    admit: bool,
    /// The space measured or read from `usage`; null when unknown.
    used: ?u64 = null,
    maintained: bool = false,
    evicted: []const Eviction = &.{},
};

/// Whether a capture may write now; runs maintenance when the space is over
/// the budget. Memory belongs to `arena`.
pub fn admit(arena: Allocator, config: Config) Allocator.Error!Admission {
    const io = io_mod.getIo();
    const captures = try std.Io.Dir.path.join(arena, &.{ config.profile_root, "captures" });
    if (!capture_store.exists(io, captures)) return .{ .admit = true, .used = 0 };
    const usage_path = try std.Io.Dir.path.join(arena, &.{ captures, "usage" });
    const cached = try readUsage(arena, io, usage_path);
    const fresh = try refresh(arena, io, captures, cached, config.now_ms, config.deadline) orelse return .{ .admit = false };
    var usage = fresh.usage;
    usage.maintained_ms = if (cached) |value| value.maintained_ms else 0;
    if (fresh.changed) writeUsage(arena, io, usage_path, usage);
    if (usage.total <= config.budget) return .{ .admit = true, .used = usage.total };
    // Maintenance that could not get under the budget is not retried until
    // the interval has passed.
    const since = config.now_ms - usage.maintained_ms;
    if (since >= 0 and since < measure_interval_ms) return .{ .admit = false, .used = usage.total };
    return maintain(arena, io, config, captures, usage_path, usage);
}

fn maintain(arena: Allocator, io: std.Io, config: Config, captures: []const u8, usage_path: []const u8, measured: Usage) Allocator.Error!Admission {
    // One maintenance per profile; another process's leaves this capture out.
    const lock_path = try std.Io.Dir.path.join(arena, &.{ captures, "maintenance.lock" });
    const lock = std.Io.Dir.createFileAbsolute(io, lock_path, .{ .truncate = false, .read = true }) catch return .{ .admit = false, .used = measured.total };
    defer lock.close(io);
    if (!(lock.tryLock(io, .exclusive) catch false)) return .{ .admit = false, .used = measured.total };

    const limits: safe_git.Limits = .{ .deadline = config.deadline };
    const ready = switch (try safe_git.prepareStore(arena, limits)) {
        .ready => |value| value,
        .refused => return .{ .admit = false, .used = measured.total },
    };
    const stores = try listStores(arena, io, captures);
    // A store left unpruned here stops eviction below once a session's refs
    // leave it.
    for (stores) |store| _ = try collect(arena, io, ready, store, config.deadline);
    // Pruning rewrote the stores, so their fingerprints changed.
    var usage = if (try refresh(arena, io, captures, measured, config.now_ms, config.deadline)) |value| value.usage else measured;
    var used = usage.total;

    var evicted: std.ArrayList(Eviction) = .empty;
    var stopped: ?[]const u8 = null;
    if (used > config.target) {
        const candidates = try inventory(arena, ready, stores, config.current_key, limits);
        // Sessions that no longer exist first, then the longest unused.
        for (candidates) |*candidate| candidate.orphan = !config.sessions.exists(config.sessions.ctx, candidate.key);
        sort_utils.sort(Candidate, candidates, {}, Candidate.before);
        const journal = try std.Io.Dir.path.join(arena, &.{ captures, "evictions.jsonl" });
        for (candidates) |candidate| {
            if (used <= config.target) break;
            if (capture_store.pastDeadline(io, config.deadline)) {
                stopped = "deadline";
                break;
            }
            if (!candidate.orphan and config.sessions.busy(config.sessions.ctx, candidate.key)) continue;
            const reason: EvictionReason = if (candidate.orphan) .orphan else .budget;
            const line: JournalLine = .{ .phase = .intent, .at_ms = config.now_ms, .key = candidate.key, .reason = reason, .refs = candidate.refs.items.len };
            // The intent is recorded before any ref goes; a failed record
            // stops maintenance.
            appendJournal(arena, io, journal, line) catch {
                stopped = "journal_failed";
                break;
            };
            var deleted: usize = 0;
            var touched: std.ArrayList(usize) = .empty;
            for (candidate.refs.items) |ref| {
                const store = stores[ref.store];
                switch (try capture_store.storeOutput(arena, ready, try maintenanceStore(arena, store), .{ .delete_ref = .{ .ref = ref.name, .old = ref.oid } }, limits)) {
                    .ok => {
                        deleted += 1;
                        if (std.mem.findScalar(usize, touched.items, ref.store) == null) try touched.append(arena, ref.store);
                    },
                    .failed => |failure| debug_trace.logf("workspace", "event=workspace_capture_ref_kept ref={s} failure={s}", .{ ref.name, @tagName(failure) }),
                }
            }
            // What the deletes did: a ref a capture moved meanwhile stays.
            var done = line;
            done.phase = .done;
            done.refs = deleted;
            done.kept = candidate.refs.items.len - deleted;
            const recorded = if (appendJournal(arena, io, journal, done)) true else |_| false;
            if (deleted > 0) {
                debug_trace.logf("workspace", "event=workspace_capture_evicted session_key={s} reason={s} refs={d}", .{ candidate.key, @tagName(reason), deleted });
                try evicted.append(arena, .{ .key = candidate.key, .reason = reason, .refs = deleted });
            }
            if (!recorded) {
                stopped = "journal_failed";
                break;
            }
            // The space drops only once the stores the refs left are pruned
            // and measured; without that, eviction would go on past what the
            // budget needs.
            for (touched.items) |index| {
                if (!try collect(arena, io, ready, stores[index], config.deadline)) {
                    stopped = "prune_failed";
                    break;
                }
            }
            if (stopped != null) break;
            // Only the stores the refs left were pruned, so only they are
            // walked again.
            const fresh = try refresh(arena, io, captures, usage, config.now_ms, config.deadline) orelse {
                stopped = "measure_failed";
                break;
            };
            usage = fresh.usage;
            used = usage.total;
        }
    }
    if (stopped) |why| debug_trace.logf("workspace", "event=workspace_capture_maintenance_stopped reason={s} used={d}", .{ why, used });
    // The last measure that succeeded.
    usage.maintained_ms = config.now_ms;
    writeUsage(arena, io, usage_path, usage);
    return .{ .admit = used <= config.budget, .used = used, .maintained = true, .evicted = evicted.items };
}

const Ref = struct { store: usize, name: []const u8, oid: []const u8 };

const Candidate = struct {
    key: []const u8,
    /// The newest capture's time across the session's refs.
    last: i64,
    orphan: bool = false,
    refs: std.ArrayList(Ref) = .empty,

    fn before(_: void, a: Candidate, b: Candidate) bool {
        if (a.orphan != b.orphan) return a.orphan;
        if (a.last != b.last) return a.last < b.last;
        return std.mem.order(u8, a.key, b.key) == .lt;
    }
};

/// Every session with captures, but `current_key`'s, with its refs. A store
/// whose refs cannot be listed offers none.
fn inventory(arena: Allocator, ready: safe_git.StoreReady, stores: []const []const u8, current_key: []const u8, limits: safe_git.Limits) Allocator.Error![]Candidate {
    var by_key: std.StringArrayHashMapUnmanaged(Candidate) = .empty;
    for (stores, 0..) |store, index| {
        const listing = switch (try capture_store.storeOutput(arena, ready, try maintenanceStore(arena, store), .list_refs, limits)) {
            .ok => |stdout| stdout,
            .failed => continue,
        };
        var lines = std.mem.splitScalar(u8, listing, '\n');
        while (lines.next()) |line| {
            const parsed = parseRefLine(line) orelse continue;
            if (std.mem.eql(u8, parsed.key, current_key)) continue;
            const entry = try by_key.getOrPut(arena, parsed.key);
            if (!entry.found_existing) entry.value_ptr.* = .{ .key = parsed.key, .last = parsed.seconds };
            entry.value_ptr.last = @max(entry.value_ptr.last, parsed.seconds);
            try entry.value_ptr.refs.append(arena, .{ .store = index, .name = parsed.name, .oid = parsed.oid });
        }
    }
    return by_key.values();
}

const RefLine = struct { name: []const u8, key: []const u8, oid: []const u8, seconds: i64 };

/// `refs/fx/sessions/<key>/<worktree> <object> <seconds>`; null for anything
/// else.
fn parseRefLine(line: []const u8) ?RefLine {
    var fields = std.mem.splitScalar(u8, line, ' ');
    const name = fields.next() orelse return null;
    const oid = fields.next() orelse return null;
    const seconds = std.fmt.parseInt(i64, fields.next() orelse return null, 10) catch return null;
    if (fields.next() != null) return null;
    const prefix = "refs/fx/sessions/";
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    var segments = std.mem.splitScalar(u8, name[prefix.len..], '/');
    const key = segments.next() orelse return null;
    const worktree = segments.next() orelse return null;
    if (segments.next() != null or !isKey(key) or !isKey(worktree)) return null;
    if (!safe_git.isOid(oid, .sha1) and !safe_git.isOid(oid, .sha256)) return null;
    return .{ .name = name, .key = key, .oid = oid, .seconds = seconds };
}

fn isKey(text: []const u8) bool {
    return isLowerHex(text, 32);
}

fn isLowerHex(text: []const u8, len: usize) bool {
    if (text.len != len) return false;
    for (text) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

/// Packs and prunes one store under all its capture locks, with the capture
/// indexes deleted first. False when a lock stayed held or git failed; the
/// store is then left unpruned.
fn collect(arena: Allocator, io: std.Io, ready: safe_git.StoreReady, store_dir: []const u8, deadline: std.Io.Clock.Timestamp) Allocator.Error!bool {
    var locks: std.ArrayList(std.Io.File) = .empty;
    defer for (locks.items) |file| file.close(io);
    // `init.lock` first: a capture that has not passed it has written
    // nothing, and the worktrees listed after it are all there are.
    if (!try lockFile(arena, io, &locks, try capture_store.initLockPath(arena, store_dir), store_dir, deadline)) return false;
    const worktrees = try capture_store.worktreesDir(arena, store_dir);
    var names: std.ArrayList([]const u8) = .empty;
    if (std.Io.Dir.openDirAbsolute(io, worktrees, .{ .iterate = true })) |dir_value| {
        var dir = dir_value;
        defer dir.close(io);
        var entries = dir.iterate();
        while (entries.next(io) catch null) |entry| {
            if (entry.kind == .directory) try names.append(arena, try arena.dupe(u8, entry.name));
        }
    } else |_| {}
    // One order for every maintenance, so two never wait on each other.
    sort_utils.sort([]const u8, names.items, {}, lessThan);
    for (names.items) |name| {
        if (!try lockFile(arena, io, &locks, try std.Io.Dir.path.join(arena, &.{ worktrees, name, capture_store.worktree_lock_name }), store_dir, deadline)) return false;
    }
    for (names.items) |name| {
        const index = try std.Io.Dir.path.join(arena, &.{ worktrees, name, capture_store.worktree_index_name });
        std.Io.Dir.deleteFileAbsolute(io, index) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return false,
        };
    }
    switch (try capture_store.storeOutput(arena, ready, try maintenanceStore(arena, store_dir), .gc, .{ .deadline = deadline })) {
        .ok => return true,
        .failed => |failure| {
            debug_trace.logf("workspace", "event=workspace_capture_gc_failed store={s} failure={s}", .{ store_dir, @tagName(failure) });
            return false;
        },
    }
}

/// Takes an exclusive lock on `path`, waiting until `deadline`; the file
/// joins `locks`, which the caller closes.
fn lockFile(arena: Allocator, io: std.Io, locks: *std.ArrayList(std.Io.File), path: []const u8, store_dir: []const u8, deadline: std.Io.Clock.Timestamp) Allocator.Error!bool {
    const file = std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = false, .read = true }) catch return false;
    locks.append(arena, file) catch |err| {
        file.close(io);
        return err;
    };
    while (!(file.tryLock(io, .exclusive) catch return false)) {
        if (capture_store.pastDeadline(io, deadline)) {
            debug_trace.logf("workspace", "event=workspace_capture_store_busy store={s}", .{store_dir});
            return false;
        }
        io_mod.sleep(10 * std.time.ns_per_ms);
    }
    return true;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// The store's git directory for commands that touch neither an index nor
/// a worktree; git still needs both names, so they point inside the store.
fn maintenanceStore(arena: Allocator, store_dir: []const u8) Allocator.Error!safe_git.Store {
    return .{
        .git_dir = try capture_store.storeGitDir(arena, store_dir),
        .index_file = try std.Io.Dir.path.join(arena, &.{ store_dir, "maintenance.index" }),
        .work_tree = store_dir,
        .scratch_dir = store_dir,
    };
}

/// The repository folders under `captures` whose store is complete.
fn listStores(arena: Allocator, io: std.Io, captures: []const u8) Allocator.Error![]const []const u8 {
    var stores: std.ArrayList([]const u8) = .empty;
    var dir = std.Io.Dir.openDirAbsolute(io, captures, .{ .iterate = true }) catch return stores.items;
    defer dir.close(io);
    var entries = dir.iterate();
    while (entries.next(io) catch null) |entry| {
        if (entry.kind != .directory or !isKey(entry.name)) continue;
        const store_dir = try std.Io.Dir.path.join(arena, &.{ captures, entry.name });
        const head = try std.Io.Dir.path.join(arena, &.{ try capture_store.storeGitDir(arena, store_dir), "HEAD" });
        if (capture_store.exists(io, head)) try stores.append(arena, store_dir);
    }
    sort_utils.sort([]const u8, stores.items, {}, lessThan);
    return stores.items;
}

/// One store's measure in `usage`.
const StoreUsage = struct {
    name: []const u8,
    bytes: u64,
    at_ms: i64,
    fingerprint: u64,

    fn before(_: void, a: StoreUsage, b: StoreUsage) bool {
        return std.mem.order(u8, a.name, b.name) == .lt;
    }
};

const Usage = struct {
    /// The stores and the files beside them.
    total: u64,
    /// When maintenance last ran; 0 when it never did.
    maintained_ms: i64 = 0,
    /// In name order.
    stores: []const StoreUsage,
};

const Refreshed = struct {
    usage: Usage,
    /// Whether `usage` differs from the cache it started from.
    changed: bool,
};

/// The space the captures folder takes now. A store whose measure in
/// `cached` still holds keeps it; the others are walked. Null when a walk
/// fails or the deadline passes. Memory belongs to `arena`.
fn refresh(arena: Allocator, io: std.Io, captures: []const u8, cached: ?Usage, now_ms: i64, deadline: std.Io.Clock.Timestamp) Allocator.Error!?Refreshed {
    var dir = std.Io.Dir.openDirAbsolute(io, captures, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var stores: std.ArrayList(StoreUsage) = .empty;
    var beside: u64 = 0;
    var walked = false;
    var entries = dir.iterate();
    while (entries.next(io) catch return null) |entry| {
        switch (entry.kind) {
            .file => {
                const stat = dir.statFile(io, entry.name, .{ .follow_symlinks = false }) catch continue;
                beside +|= std.mem.alignForward(u64, stat.size, 4096);
                continue;
            },
            .directory => {},
            else => continue,
        }
        const path = try std.Io.Dir.path.join(arena, &.{ captures, entry.name });
        if (!isKey(entry.name)) {
            beside +|= measure(arena, io, path, deadline) orelse return null;
            continue;
        }
        const fingerprint = try fingerprintStore(arena, io, path);
        if (reusable(cached, entry.name, fingerprint, now_ms)) |kept| {
            try stores.append(arena, kept);
            continue;
        }
        walked = true;
        try stores.append(arena, .{
            .name = try arena.dupe(u8, entry.name),
            .bytes = measure(arena, io, path, deadline) orelse return null,
            .at_ms = now_ms,
            .fingerprint = fingerprint,
        });
    }
    sort_utils.sort(StoreUsage, stores.items, {}, StoreUsage.before);
    var total = beside;
    for (stores.items) |store| total +|= store.bytes;
    const changed = if (cached) |value| walked or value.stores.len != stores.items.len or value.total != total else true;
    return .{ .usage = .{ .total = total, .stores = stores.items }, .changed = changed };
}

/// The store's measure in `cached` when its objects have not changed since
/// and it is younger than `measure_interval_ms`.
fn reusable(cached: ?Usage, name: []const u8, fingerprint: u64, now_ms: i64) ?StoreUsage {
    if (fingerprint == 0) return null;
    const usage = cached orelse return null;
    for (usage.stores) |store| {
        if (!std.mem.eql(u8, store.name, name)) continue;
        const age = now_ms - store.at_ms;
        if (store.fingerprint != fingerprint or age < 0 or age >= measure_interval_ms) return null;
        return store;
    }
    return null;
}

/// A hash of the times of the store's object folders: the objects folder
/// and each folder in it. Zero when they cannot be read or one changed
/// within `racy_ms`, so the store is walked next time too.
fn fingerprintStore(arena: Allocator, io: std.Io, store_dir: []const u8) Allocator.Error!u64 {
    const objects = try std.Io.Dir.path.join(arena, &.{ try capture_store.storeGitDir(arena, store_dir), "objects" });
    // The clock first: a write after it shows as racy.
    const now_ns = io_mod.nanoTimestamp();
    var dir = std.Io.Dir.openDirAbsolute(io, objects, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var newest: i128 = (dir.stat(io) catch return 0).mtime.nanoseconds;
    var sum = folderHash("", newest);
    var entries = dir.iterate();
    while (entries.next(io) catch return 0) |entry| {
        if (entry.kind != .directory) continue;
        const mtime: i128 = (dir.statFile(io, entry.name, .{}) catch return 0).mtime.nanoseconds;
        sum +%= folderHash(entry.name, mtime);
        newest = @max(newest, mtime);
    }
    if (newest >= now_ns - racy_ms * std.time.ns_per_ms) return 0;
    return @max(sum, 1);
}

fn folderHash(name: []const u8, mtime: i128) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(name);
    hasher.update(std.mem.asBytes(&mtime));
    return hasher.final();
}

/// Bytes the folder's files take, each rounded up to a 4 KiB block; null
/// when the folder cannot be read or the deadline passes.
fn measure(arena: Allocator, io: std.Io, root: []const u8, deadline: std.Io.Clock.Timestamp) ?u64 {
    var dir = std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var walker = dir.walk(arena) catch return null;
    defer walker.deinit();
    var total: u64 = 0;
    var seen: usize = 0;
    while (walker.next(io) catch return null) |entry| {
        seen += 1;
        if (seen % 1024 == 0 and capture_store.pastDeadline(io, deadline)) return null;
        if (entry.kind != .file) continue;
        const stat = entry.dir.statFile(io, entry.basename, .{ .follow_symlinks = false }) catch continue;
        total += std.mem.alignForward(u64, stat.size, 4096);
    }
    return total;
}

/// `captures/usage`. Null when missing or in any other format.
fn readUsage(arena: Allocator, io: std.Io, path: []const u8) Allocator.Error!?Usage {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    return parseUsage(arena, text);
}

/// The text `formatUsage` writes; null for anything else, such as stores
/// out of order or bytes that add up to more than the total.
fn parseUsage(arena: Allocator, text: []const u8) Allocator.Error!?Usage {
    if (text.len == 0 or text[text.len - 1] != '\n') return null;
    var lines = std.mem.splitScalar(u8, text[0 .. text.len - 1], '\n');
    var header = std.mem.splitScalar(u8, lines.first(), ' ');
    if (!std.mem.eql(u8, header.first(), "v2")) return null;
    const total = std.fmt.parseInt(u64, header.next() orelse return null, 10) catch return null;
    const maintained_ms = std.fmt.parseInt(i64, header.next() orelse return null, 10) catch return null;
    if (header.next() != null) return null;
    var stores: std.ArrayList(StoreUsage) = .empty;
    var sum: u64 = 0;
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ' ');
        const name = fields.first();
        if (!isKey(name)) return null;
        if (stores.items.len > 0 and std.mem.order(u8, stores.items[stores.items.len - 1].name, name) != .lt) return null;
        const bytes = std.fmt.parseInt(u64, fields.next() orelse return null, 10) catch return null;
        const at_ms = std.fmt.parseInt(i64, fields.next() orelse return null, 10) catch return null;
        const fingerprint_text = fields.next() orelse return null;
        if (!isLowerHex(fingerprint_text, 16)) return null;
        const fingerprint = std.fmt.parseInt(u64, fingerprint_text, 16) catch return null;
        if (fields.next() != null) return null;
        sum = std.math.add(u64, sum, bytes) catch return null;
        try stores.append(arena, .{ .name = name, .bytes = bytes, .at_ms = at_ms, .fingerprint = fingerprint });
    }
    if (sum > total) return null;
    return .{ .total = total, .maintained_ms = maintained_ms, .stores = stores.items };
}

fn formatUsage(arena: Allocator, usage: Usage) Allocator.Error![]u8 {
    var text: std.ArrayList(u8) = .empty;
    try text.print(arena, "v2 {d} {d}\n", .{ usage.total, usage.maintained_ms });
    for (usage.stores) |store| try text.print(arena, "{s} {d} {d} {x:0>16}\n", .{ store.name, store.bytes, store.at_ms, store.fingerprint });
    return text.items;
}

/// Replaces `usage` through a temporary file; a failure only means the next
/// capture walks the stores again.
fn writeUsage(arena: Allocator, io: std.Io, path: []const u8, usage: Usage) void {
    const text = formatUsage(arena, usage) catch return;
    const temporary = arena.print("{s}.tmp-{d}", .{ path, io_mod.nanoTimestamp() }) catch return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = temporary, .data = text, .flags = .{ .permissions = .fromMode(0o600) } }) catch return;
    std.Io.Dir.renameAbsolute(temporary, path, io) catch std.Io.Dir.deleteFileAbsolute(io, temporary) catch {};
}

/// One line of `evictions.jsonl`. The intent's `refs` are the refs found;
/// the done line's are the refs deleted, and `kept` those a capture moved.
const JournalLine = struct {
    phase: enum { intent, done },
    at_ms: i64,
    key: []const u8,
    reason: EvictionReason,
    refs: usize,
    kept: usize = 0,
};

/// Appends one line to the journal and syncs it.
fn appendJournal(arena: Allocator, io: std.Io, path: []const u8, entry: JournalLine) !void {
    const head = try arena.print("{{\"v\":1,\"phase\":\"{s}\",\"at_ms\":{d},\"session_key\":\"{s}\",\"reason\":\"{s}\",\"refs\":{d}", .{ @tagName(entry.phase), entry.at_ms, entry.key, @tagName(entry.reason), entry.refs });
    const line = switch (entry.phase) {
        .intent => try arena.print("{s}}}\n", .{head}),
        .done => try arena.print("{s},\"kept\":{d}}}\n", .{ head, entry.kept }),
    };
    const file = try std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = false, .read = true, .permissions = .fromMode(0o600) });
    defer file.close(io);
    const end = (try file.stat(io)).size;
    try file.writePositionalAll(io, line, end);
    try file.sync(io);
}

test "capture retention reads only well-formed capture refs" {
    const oid = "0123456789abcdef0123456789abcdef01234567";
    const key = "00112233445566778899aabbccddeeff";
    const wt = "ffeeddccbbaa99887766554433221100";
    const good = try std.fmt.allocPrint(std.testing.allocator, "refs/fx/sessions/{s}/{s} {s} 1700000000", .{ key, wt, oid });
    defer std.testing.allocator.free(good);
    const parsed = parseRefLine(good).?;
    try std.testing.expectEqualStrings(key, parsed.key);
    try std.testing.expectEqualStrings(oid, parsed.oid);
    try std.testing.expectEqual(@as(i64, 1_700_000_000), parsed.seconds);
    for ([_][]const u8{
        "",
        "refs/heads/main " ++ oid ++ " 1",
        "refs/fx/sessions/" ++ key ++ " " ++ oid ++ " 1",
        "refs/fx/sessions/" ++ key ++ "/" ++ wt ++ "/x " ++ oid ++ " 1",
        "refs/fx/sessions/" ++ key ++ "/" ++ wt ++ " nothex 1",
        "refs/fx/sessions/" ++ key ++ "/" ++ wt ++ " " ++ oid ++ " soon",
        "refs/fx/sessions/" ++ key ++ "/" ++ wt ++ " " ++ oid ++ " 1 extra",
        "refs/fx/sessions/ABCDEF33445566778899aabbccddeeff/" ++ wt ++ " " ++ oid ++ " 1",
    }) |line| try std.testing.expect(parseRefLine(line) == null);
}

test "capture retention evicts orphans first, then the longest unused, ties by key" {
    var items = [_]Candidate{
        .{ .key = "b", .last = 10 },
        .{ .key = "a", .last = 10 },
        .{ .key = "c", .last = 5 },
        .{ .key = "d", .last = 99, .orphan = true },
    };
    sort_utils.sort(Candidate, &items, {}, Candidate.before);
    const expected = [_][]const u8{ "d", "c", "a", "b" };
    for (expected, items) |key, item| try std.testing.expectEqualStrings(key, item.key);
}

test "capture retention reads back every ref line and usage it accepts on fuzzed bytes" {
    try std.testing.fuzz({}, fuzzParse, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "refs/fx/sessions/00112233445566778899aabbccddeeff/ffeeddccbbaa99887766554433221100 0123456789abcdef0123456789abcdef01234567 1700000000",
            "refs/fx/sessions/00112233445566778899aabbccddeeff/ffeeddccbbaa99887766554433221100 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef -0_1",
            "refs/fx/sessions/00112233445566778899aabbccddeeff/ffeeddccbbaa99887766554433221100/x 0123456789abcdef0123456789abcdef01234567 1",
            "refs/fx/sessions/0011/ffee 0123 +1",
            "v2 5368709120 0\n00112233445566778899aabbccddeeff 4096 1700000000000 0123456789abcdef\nffeeddccbbaa99887766554433221100 8192 1700000000001 0000000000000000\n",
            "v2 +1_0 -7\n00112233445566778899aabbccddeeff 1_0 -0 ffffffffffffffff\n",
            "v2 1 0\n00112233445566778899aabbccddeeff 4096 1 0123456789abcdef\n",
            "v2 9000 0\nffeeddccbbaa99887766554433221100 1 1 0123456789abcdef\n00112233445566778899aabbccddeeff 1 1 0123456789abcdef\n",
            "v2 0 0\n",
            "5368709120 1700000000000\n",
            "v2 1 2 3\n",
            " ",
        }) ++ @import("fuzz_corpus").capture_retention_parse.*),
    });
}

fn fuzzParse(_: void, smith: *std.testing.Smith) anyerror!void {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buffer: [1024]u8 = undefined;
    const bytes = buffer[0..@intCast(smith.slice(&buffer))];
    // An accepted ref line written back the way git lists it reads the same.
    if (parseRefLine(bytes)) |parsed| {
        try std.testing.expect(std.mem.startsWith(u8, parsed.name, "refs/fx/sessions/"));
        try std.testing.expectEqualStrings(parsed.key, parsed.name["refs/fx/sessions/".len..][0..32]);
        const again = try alloc.print("{s} {s} {d}", .{ parsed.name, parsed.oid, parsed.seconds });
        defer alloc.free(again);
        const reparsed = parseRefLine(again) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(parsed.name, reparsed.name);
        try std.testing.expectEqualStrings(parsed.key, reparsed.key);
        try std.testing.expectEqualStrings(parsed.oid, reparsed.oid);
        try std.testing.expectEqual(parsed.seconds, reparsed.seconds);
    }
    // So does an accepted usage written back the way `writeUsage` writes it.
    if (try parseUsage(arena, bytes)) |usage| {
        var sum: u64 = 0;
        for (usage.stores) |store| sum += store.bytes;
        try std.testing.expect(sum <= usage.total);
        const again = try formatUsage(arena, usage);
        const reparsed = (try parseUsage(arena, again)) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(usage.total, reparsed.total);
        try std.testing.expectEqual(usage.maintained_ms, reparsed.maintained_ms);
        try std.testing.expectEqual(usage.stores.len, reparsed.stores.len);
        for (usage.stores, reparsed.stores) |a, b| {
            try std.testing.expectEqualStrings(a.name, b.name);
            try std.testing.expectEqual(a.bytes, b.bytes);
            try std.testing.expectEqual(a.at_ms, b.at_ms);
            try std.testing.expectEqual(a.fingerprint, b.fingerprint);
        }
        try std.testing.expectEqualStrings(again, try formatUsage(arena, reparsed));
    }
}
