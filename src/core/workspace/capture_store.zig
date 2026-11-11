//! One workspace capture of a git repository into fx's own store.
//!
//! Each repository gets a bare store under the profile, keyed by its common
//! git directory, with alternates into the user's objects so unchanged files
//! cost nothing. Each worktree gets its own capture index, lock and scratch
//! directory. A capture lists the worktree, applies `workspace_capture`'s
//! policy, writes a tree, and appends a commit to the ref for the session and
//! worktree, `refs/fx/sessions/<session key>/<worktree key>`, with
//! compare-and-swap, and `encodeRecord` turns the outcome into the session's
//! `workspace_capture` item (D98). git reads the user's repository only
//! through `safe_git`'s read-only route; fx itself reads the index file to
//! copy it and checks a few files in the git directory.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const safe_git = @import("../shell_command/safe_git.zig");
const indexer = @import("../indexer/indexer.zig");
const policy = @import("workspace_capture.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const sort_utils = @import("../shared/sort_utils.zig");

const Allocator = std.mem.Allocator;

/// The repository a capture read, as absolute paths with every symlink
/// resolved, so two spellings of one repository name the same one.
pub const Repository = struct {
    /// Root of the worktree being captured.
    work_tree: []const u8,
    /// This worktree's git directory (`.git`, or `.git/worktrees/<name>`).
    git_dir: []const u8,
    /// The common git directory that holds the objects.
    common_dir: []const u8,
};

pub const Phase = enum { start, end };

pub const Request = struct {
    /// The fx profile root, such as `~/.fx`.
    profile_root: []const u8,
    /// An absolute folder inside the worktree to capture, such as the
    /// session's working directory. The whole worktree that holds it is
    /// captured, and `Outcome.repository` names it.
    path: []const u8,
    /// fx's session id, `[A-Za-z0-9._-]{1,255}` not starting with `.`.
    /// The ref names it by a hash, so every valid id fits git's ref rules.
    session_id: []const u8,
    phase: Phase,
    unix_seconds: i64,
    /// One budget for the whole capture, shared by every git command.
    deadline: std.Io.Clock.Timestamp,
    limits: policy.Limits = .{},
    /// Thread-safe allocator for the native indexer, which lists folders on
    /// several threads. Its memory is freed before `capture` returns.
    scan_allocator: Allocator,
};

pub const Status = enum { complete, partial, failed, unavailable };

/// HEAD as the capture saw it: not read, a repository with no commit yet,
/// or a commit.
pub const Head = union(enum) { unknown, unborn, commit: []const u8 };

/// Where the untracked listing came from.
pub const Listing = enum { indexer, git };

/// How the capture index started: a copy of the user's index, a rebuild
/// from HEAD (split index), or this worktree's index from a previous capture.
pub const IndexStart = enum { copied, rebuilt, persisted };

/// What one capture did. A field stays at its default when the capture
/// stopped before measuring it, so a failure never claims a fact it did not
/// see.
pub const Outcome = struct {
    status: Status,
    /// Set for every status but `complete`.
    reason: ?policy.Reason = null,
    /// Set once git has resolved the repository.
    repository: ?Repository = null,
    /// The ref the capture extends, set with `repository`.
    ref: ?[]const u8 = null,
    head: Head = .unknown,
    object_format: ?safe_git.ObjectFormat = null,
    listing: ?Listing = null,
    index: ?IndexStart = null,
    /// Set for `complete` and `partial`.
    tree: ?[]const u8 = null,
    commit: ?[]const u8 = null,
    /// Whether the tree can be compared with the user's commits.
    comparable: bool = false,
    /// Paths the policy left out, borrowed from the arena.
    excluded: []const policy.Exclusion = &.{},
    /// The tool whose action reached this repository first in the turn, for
    /// a start capture it triggered; null for the turn's own captures (D98).
    /// Set by the caller, not by `capture`.
    trigger_tool: ?[]const u8 = null,
};

/// Extra time the one-time setup may take: creating a repository's store and
/// starting a worktree's capture index from the user's. It runs once, and in
/// a large repository it alone can use up a turn's capture budget, so the
/// capture's deadline moves later by the time setup took, at most this much
/// beyond the deadline.
const setup_budget_ms: i64 = 10_000;

/// A capture index lock older than this was left by a git that died: fx's
/// own git runs only under the worktree lock and stops at the capture's
/// deadline plus the setup budget, both far shorter.
const stale_index_lock_ms: i64 = 2 * std.time.ms_per_min;

/// Captures `request.repository` into its store. Every failure is an
/// `Outcome`; only allocation failure is returned as an error. Memory belongs
/// to `arena`.
pub fn capture(arena: Allocator, request: Request) Allocator.Error!Outcome {
    if (!validSessionId(request.session_id)) return .{ .status = .failed, .reason = .invalid_request };
    for ([_][]const u8{ request.profile_root, request.path }) |path| {
        if (!std.Io.Dir.path.isAbsolute(path)) return .{ .status = .failed, .reason = .invalid_request };
    }
    var run: Run = .{ .arena = arena, .io = io_mod.getIo(), .request = request, .deadline = request.deadline };
    if (try run.resolve()) |done| return done;
    if (try run.lockWorktree()) |done| return done;
    defer if (run.lock) |*lock| lock.close(run.io);
    if (try run.clearStaleIndexLock()) |done| return done;
    if (try run.setUp()) |done| return done;
    if (try run.select()) |done| return done;
    if (try run.apply()) |done| return done;
    return run.commit();
}

/// One capture's state, filled in step by step. Each step returns the
/// final outcome when the capture stops there, or null to go on.
const Run = struct {
    arena: Allocator,
    io: std.Io,
    request: Request,
    /// The capture's deadline, moved later by the time setup took.
    deadline: std.Io.Clock.Timestamp,
    outcome: Outcome = .{ .status = .complete },
    ready: safe_git.Ready = undefined,
    store_ready: safe_git.StoreReady = undefined,
    facts: safe_git.RepositoryFacts = undefined,
    canonical: Repository = undefined,
    ref: []const u8 = undefined,
    /// The repository's folder under the profile (`storeDir`).
    store_dir: []const u8 = undefined,
    store: safe_git.Store = undefined,
    /// The worktree's lock, held from `lockWorktree` to the end.
    lock: ?Lock = null,
    /// What the user's git tracks, and what the capture index held before.
    tracked: []const Staged = &.{},
    captured: []const Staged = &.{},
    tracked_paths: std.StringHashMapUnmanaged(Staged) = .empty,
    selection: policy.Selection = undefined,

    fn limits(self: *const Run) safe_git.Limits {
        return .{ .deadline = self.deadline };
    }

    fn fail(self: *const Run, status: Status, reason: policy.Reason) Outcome {
        return withFailure(self.outcome, status, reason);
    }

    fn gitFail(self: *const Run, failure: safe_git.Failure) Outcome {
        return withGitFailure(self.outcome, failure);
    }

    /// The user's repository: read only, through the agent's read-only
    /// prelude. A refusal after the deadline is the deadline's: prepare's own
    /// git runs stop there too.
    fn resolve(self: *Run) Allocator.Error!?Outcome {
        const arena = self.arena;
        self.ready = switch (try safe_git.prepareWithin(arena, self.request.path, self.limits())) {
            .ready => |value| value,
            .refused => return deadlineOr(self.io, self.deadline, .{ .status = .unavailable, .reason = .git_refused }),
        };
        // No repository holds the folder.
        if (self.ready.git_dir == null) return .{ .status = .unavailable, .reason = .not_git };
        // The store route needs git 2.29; check it before `repositoryFacts`,
        // which already uses a 2.29 option, so old git is unavailable, not
        // failed.
        self.store_ready = switch (try safe_git.prepareStore(arena, self.limits())) {
            .ready => |value| value,
            .refused => return deadlineOr(self.io, self.deadline, .{ .status = .unavailable, .reason = .git_refused }),
        };
        self.facts = (try safe_git.repositoryFacts(arena, self.ready, self.request.path, self.limits())) orelse
            return deadlineOr(self.io, self.deadline, .{ .status = .failed, .reason = .io_error });
        // The repository as git resolves it, with symlinks resolved: every
        // key below uses these spellings, so `/tmp/x`, `/private/tmp/x` and
        // any folder inside the worktree reach the same store, index and ref.
        self.outcome = .{
            .status = .complete,
            .head = if (self.facts.head) |oid| .{ .commit = oid } else .unborn,
            .object_format = self.facts.object_format,
        };
        self.canonical = .{
            .work_tree = try resolvedPath(arena, self.facts.work_tree) orelse return self.fail(.failed, .io_error),
            .git_dir = try resolvedPath(arena, self.facts.git_dir) orelse return self.fail(.failed, .io_error),
            .common_dir = try resolvedPath(arena, self.facts.common_dir) orelse return self.fail(.failed, .io_error),
        };
        // The outcome claims nothing here: HEAD, the repository and the ref
        // would all be the other checkout's.
        if (!try ownsGitDir(arena, self.io, self.canonical, self.request.path)) {
            return .{ .status = .unavailable, .reason = .foreign_git_dir };
        }
        self.outcome.repository = self.canonical;
        // One chain per session and worktree: two worktrees of one
        // repository in the same session never race for one ref or mix their
        // trees.
        self.ref = try sessionRefName(arena, self.request.session_id, self.canonical.git_dir);
        self.outcome.ref = self.ref;
        // A sparse index holds folder entries the store cannot expand without
        // the user's sparse-checkout patterns.
        if (self.facts.sparse_index) return self.fail(.unavailable, .index_sparse);
        return null;
    }

    /// Layout and the worktree lock, held for the whole capture. flock is
    /// released by the kernel if fx dies, so a crash never leaves it held.
    fn lockWorktree(self: *Run) Allocator.Error!?Outcome {
        const arena = self.arena;
        const store_dir = try storeDir(arena, self.request.profile_root, self.canonical.common_dir);
        self.store_dir = store_dir;
        const worktree_dir = try worktreeDir(arena, store_dir, self.canonical.git_dir);
        const scratch_dir = try std.Io.Dir.path.join(arena, &.{ worktree_dir, "scratch" });
        // Captures hold the user's uncommitted work: every folder fx creates
        // for them is private, whatever the umask.
        for ([_][]const u8{ try std.Io.Dir.path.join(arena, &.{ self.request.profile_root, "captures" }), store_dir, try std.Io.Dir.path.join(arena, &.{ store_dir, "worktrees" }), worktree_dir, scratch_dir }) |dir| {
            ensurePrivateDir(self.io, dir) catch return self.fail(.failed, .io_error);
        }
        self.lock = acquireLock(self.io, try std.Io.Dir.path.join(arena, &.{ worktree_dir, "lock" }), self.deadline) catch |err| return switch (err) {
            error.Busy => self.fail(.unavailable, .capture_locked),
            error.Unavailable => self.fail(.failed, .io_error),
        };
        self.store = .{
            .git_dir = try storeGitDir(arena, store_dir),
            .index_file = try std.Io.Dir.path.join(arena, &.{ worktree_dir, "index" }),
            .work_tree = self.canonical.work_tree,
            .scratch_dir = scratch_dir,
            .conversions = self.facts.conversions,
        };
        return null;
    }

    /// A git that outlived its capture, such as one a killed fx left, can
    /// leave the capture index locked. Only captures holding the worktree
    /// lock run git on the index, and this one holds it, so a lock older than
    /// any capture can run is removed; a newer one is reported.
    fn clearStaleIndexLock(self: *Run) Allocator.Error!?Outcome {
        const path = try self.arena.print("{s}.lock", .{self.store.index_file});
        const stat = std.Io.Dir.cwd().statFile(self.io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return self.fail(.unavailable, .capture_locked),
        };
        const age_ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds() - stat.mtime.toMilliseconds();
        if (age_ms < stale_index_lock_ms) return self.fail(.unavailable, .capture_locked);
        std.Io.Dir.deleteFileAbsolute(self.io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return self.fail(.unavailable, .capture_locked),
        };
        debug_trace.logf("workspace", "event=workspace_capture_stale_lock_removed lock={s} age_ms={d}", .{ path, age_ms });
        return null;
    }

    /// Makes sure the store exists and the worktree has a capture index. The
    /// first capture starts the index from a copy of the user's with its
    /// timestamp, so git's racy-entry check still sees files changed in the
    /// index's second. A split index keeps entries in a shared file the copy
    /// would miss, so it is rebuilt from HEAD instead. Creating the store and
    /// the index runs on `setup_budget_ms`, and the capture's deadline moves
    /// later by the time they took.
    fn setUp(self: *Run) Allocator.Error!?Outcome {
        const arena = self.arena;
        const io = self.io;
        const clock = self.deadline.clock;
        const store_missing = !exists(io, try std.Io.Dir.path.join(arena, &.{ self.store.git_dir, "HEAD" }));
        const index_missing = !exists(io, self.store.index_file);
        const started: std.Io.Clock.Timestamp = .now(io, clock);
        const budget_end = started.addDuration(.{ .raw = .fromMilliseconds(setup_budget_ms), .clock = clock });
        const setup_deadline = if (budget_end.compare(.gt, self.deadline)) budget_end else self.deadline;
        // An existing store is only checked; its lock, which pruning also
        // holds, waits on the capture's own deadline.
        const store_deadline = if (store_missing) setup_deadline else self.deadline;
        if (try ensureStore(arena, io, self.store_ready, self.store_dir, self.store.git_dir, self.canonical.common_dir, self.facts.object_format, .{ .deadline = store_deadline }, store_deadline)) |failure| {
            return self.gitFail(failure);
        }
        self.outcome.index = .persisted;
        if (index_missing) {
            const user_index = try std.Io.Dir.path.join(arena, &.{ self.canonical.git_dir, "index" });
            if (self.facts.split_index or try hasSharedIndex(io, self.canonical.git_dir) or !exists(io, user_index)) {
                if (try runStore(arena, self.store_ready, self.store, .{ .read_tree = self.facts.head }, .{ .deadline = setup_deadline })) |failure| return self.gitFail(failure);
                self.outcome.index = .rebuilt;
            } else {
                copyPreservingTime(arena, io, user_index, self.store.index_file) catch return self.fail(.failed, .io_error);
                self.outcome.index = .copied;
            }
        }
        if (store_missing or index_missing) {
            const took = started.durationTo(.now(io, clock));
            self.deadline = self.deadline.addDuration(took);
            debug_trace.logf("workspace", "event=workspace_capture_setup store_created={} index={s} ms={d}", .{ store_missing, @tagName(self.outcome.index.?), took.raw.toMilliseconds() });
        }
        return null;
    }

    /// Lists what the user's git tracks, what the capture index holds and
    /// the untracked files, checks each on disk, and applies
    /// `workspace_capture`'s policy.
    fn select(self: *Run) Allocator.Error!?Outcome {
        const arena = self.arena;
        const io = self.io;
        const tracked_listing = switch (try safe_git.listRepository(arena, self.ready, self.canonical.work_tree, .tracked, self.limits())) {
            .ok => |stdout| stdout,
            .failed => |failure| return self.gitFail(failure),
        };
        self.tracked = safe_git.parseStageListing(arena, tracked_listing) catch return self.fail(.failed, .inconsistent);
        const index_listing = switch (try storeOutput(arena, self.store_ready, self.store, .list_index, self.limits())) {
            .ok => |stdout| stdout,
            .failed => |failure| return self.gitFail(failure),
        };
        self.captured = safe_git.parseStageListing(arena, index_listing) catch return self.fail(.failed, .inconsistent);

        // Untracked files: the native indexer, or git when it cannot read the
        // index format completely.
        for (self.tracked) |entry| try self.tracked_paths.put(arena, entry.path, entry);
        const untracked = switch (try listUntracked(arena, self.request.scan_allocator, self.ready, self.facts, self.deadline, &self.tracked_paths, &self.outcome)) {
            .listed => |value| value,
            .stopped => return self.fail(.unavailable, .untracked_timeout),
            .failed => return deadlineOr(io, self.deadline, self.fail(.failed, .io_error)),
        };
        if (pastDeadline(io, self.deadline)) return self.fail(.unavailable, .timeout);

        // Candidates with what the disk holds now.
        var candidates: std.ArrayList(policy.Candidate) = .empty;
        var disk: Disk = .{ .arena = arena, .io = io, .work_tree = self.canonical.work_tree };
        for (self.tracked, 0..) |entry, i| {
            if (i % 1024 == 1023 and pastDeadline(io, self.deadline)) return self.fail(.unavailable, .timeout);
            const found = disk.lstat(entry.path) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Unreadable => return self.fail(.failed, .io_error),
            };
            // A tracked file replaced by a folder is gone, unless it is a
            // gitlink.
            const present = found.present and ((entry.mode == .gitlink) or found.kind != .gitlink);
            try candidates.append(arena, .{
                .path = entry.path,
                .tracked = true,
                .present = present,
                .skip_worktree = entry.skip_worktree,
                .bytes = found.bytes,
                .kind = if ((entry.mode == .gitlink)) .gitlink else found.kind,
            });
        }
        for (untracked.files, 0..) |path, i| {
            if (i % 1024 == 1023 and pastDeadline(io, self.deadline)) return self.fail(.unavailable, .timeout);
            const found = disk.lstat(path) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Unreadable => return self.fail(.failed, .io_error),
            };
            try candidates.append(arena, .{ .path = path, .tracked = false, .present = found.present, .bytes = found.bytes, .kind = found.kind });
        }
        // A repository nested inside the worktree is recorded as left out,
        // never silently dropped.
        for (untracked.nested) |path| {
            try candidates.append(arena, .{ .path = path, .tracked = false, .present = true, .kind = .gitlink });
        }
        var previous: std.ArrayList([]const u8) = .empty;
        for (self.captured) |entry| try previous.append(arena, entry.path);
        self.selection = policy.select(arena, candidates.items, previous.items, self.request.limits) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidPath, error.DuplicatePath => return self.fail(.failed, .inconsistent),
        };
        return null;
    }

    /// Applies the selection to the capture index only. Paths read from disk
    /// lose the flags the index copy inherited, or git would keep their old
    /// content.
    fn apply(self: *Run) Allocator.Error!?Outcome {
        const arena = self.arena;
        const selection = self.selection;
        {
            var inherited: std.StringHashMapUnmanaged(Staged) = .empty;
            for (self.captured) |entry| if (entry.assume_unchanged or entry.skip_worktree) try inherited.put(arena, entry.path, entry);
            var assume: std.ArrayList([]const u8) = .empty;
            var skip: std.ArrayList([]const u8) = .empty;
            for (selection.read) |path| if (inherited.get(path)) |entry| {
                if (entry.assume_unchanged) try assume.append(arena, path);
                if (entry.skip_worktree) try skip.append(arena, path);
            };
            if (assume.items.len > 0) {
                if (try runStore(arena, self.store_ready, self.store, .{ .clear_flag = .{ .flag = .assume_unchanged, .paths = assume.items } }, self.limits())) |failure| return self.gitFail(failure);
            }
            if (skip.items.len > 0) {
                if (try runStore(arena, self.store_ready, self.store, .{ .clear_flag = .{ .flag = .skip_worktree, .paths = skip.items } }, self.limits())) |failure| return self.gitFail(failure);
            }
        }
        if (selection.keep_index.len > 0) {
            var entries: std.ArrayList(safe_git.IndexEntry) = .empty;
            for (selection.keep_index) |path| {
                const entry = self.tracked_paths.get(path) orelse return self.fail(.failed, .inconsistent);
                try entries.append(arena, .{ .mode = entry.mode, .oid = entry.oid, .path = path });
            }
            if (try runStore(arena, self.store_ready, self.store, .{ .index_info = entries.items }, self.limits())) |failure| return self.gitFail(failure);
        }
        // Removed paths may still be on disk (an untracked file that became
        // ignored, or went over a limit), so they are forced out.
        if (selection.remove.len > 0) {
            if (try runStore(arena, self.store_ready, self.store, .{ .force_remove = selection.remove }, self.limits())) |failure| return self.gitFail(failure);
        }
        if (selection.read.len > 0) {
            if (try runStore(arena, self.store_ready, self.store, .{ .add_remove = selection.read }, self.limits())) |failure| return self.gitFail(failure);
        }
        return null;
    }

    /// Writes the tree and the commit, and moves the session ref to it.
    fn commit(self: *Run) Allocator.Error!Outcome {
        const arena = self.arena;
        const format = self.facts.object_format;
        const tree = switch (try storeOutput(arena, self.store_ready, self.store, .write_tree, self.limits())) {
            .ok => |stdout| std.mem.trimEnd(u8, stdout, "\n"),
            .failed => |failure| return self.gitFail(failure),
        };
        if (!safe_git.isOid(tree, format)) return self.fail(.failed, .inconsistent);
        const parent_out = switch (try storeOutput(arena, self.store_ready, self.store, .{ .resolve_ref = self.ref }, self.limits())) {
            .ok => |stdout| std.mem.trimEnd(u8, stdout, "\n"),
            .failed => |failure| return self.gitFail(failure),
        };
        const parent: ?[]const u8 = if (parent_out.len == 0) null else parent_out;
        const message = try arena.print("fx capture {s} {s}\n", .{ self.request.session_id, @tagName(self.request.phase) });
        const commit_oid = switch (try storeOutput(arena, self.store_ready, self.store, .{ .commit_tree = .{ .tree = tree, .parent = parent, .message = message, .unix_seconds = self.request.unix_seconds } }, self.limits())) {
            .ok => |stdout| std.mem.trimEnd(u8, stdout, "\n"),
            .failed => |failure| return self.gitFail(failure),
        };
        if (!safe_git.isOid(commit_oid, format)) return self.fail(.failed, .inconsistent);
        if (try runStore(arena, self.store_ready, self.store, .{ .update_ref = .{ .ref = self.ref, .new = commit_oid, .old = parent } }, self.limits())) |failure| return self.gitFail(failure);

        var outcome = self.outcome;
        outcome.tree = tree;
        outcome.commit = commit_oid;
        outcome.excluded = self.selection.excluded;
        // Filters or attributes from the repository's own config never reach
        // the store, so its tree may differ from the user's.
        const repository_conversions = self.ready.filter_names.len > 0 or
            exists(self.io, try std.Io.Dir.path.join(arena, &.{ self.canonical.git_dir, "info", "attributes" })) or
            exists(self.io, try std.Io.Dir.path.join(arena, &.{ self.canonical.common_dir, "info", "attributes" }));
        outcome.comparable = self.selection.canCompareTrees(repository_conversions);
        if (lossReason(self.selection.excluded)) |reason| {
            outcome.status = .partial;
            outcome.reason = reason;
        }
        return outcome;
    }
};

/// Whether the worktree git reports is the captured folder's own: the folder
/// lies inside it, and its git directory is the one the worktree's `.git`
/// names for it. A `.git` symlink, or a `gitdir:` file pointing into another
/// checkout, makes git treat the folder as that checkout's worktree and
/// report its HEAD.
fn ownsGitDir(arena: Allocator, io: std.Io, repo: Repository, path: []const u8) Allocator.Error!bool {
    const folder = try resolvedPath(arena, path) orelse return false;
    if (!isWithin(repo.work_tree, folder)) return false;
    const dot_git = try std.Io.Dir.path.join(arena, &.{ repo.work_tree, ".git" });
    const stat = std.Io.Dir.cwd().statFile(io, dot_git, .{ .follow_symlinks = false }) catch return false;
    switch (stat.kind) {
        .directory => {
            const real = try resolvedPath(arena, dot_git) orelse return false;
            return std.mem.eql(u8, real, repo.git_dir);
        },
        .file => {
            if (!std.mem.eql(u8, repo.git_dir, repo.common_dir)) {
                // A linked worktree: its git directory records which `.git`
                // file is the worktree's, absolute or relative to itself.
                const gitdir_file = try std.Io.Dir.path.join(arena, &.{ repo.git_dir, "gitdir" });
                const recorded = std.Io.Dir.cwd().readFileAlloc(io, gitdir_file, arena, .limited(std.Io.Dir.max_path_bytes)) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return false,
                };
                const trimmed = std.mem.trimEnd(u8, recorded, "\r\n");
                const target = if (std.Io.Dir.path.isAbsolute(trimmed)) trimmed else try std.Io.Dir.path.join(arena, &.{ repo.git_dir, trimmed });
                const real_target = try resolvedPath(arena, target) orelse return false;
                const real_dot_git = try resolvedPath(arena, dot_git) orelse return false;
                return std.mem.eql(u8, real_target, real_dot_git);
            }
            // A separate git directory or a submodule's: never another
            // checkout's own `.git` folder.
            const parent = std.Io.Dir.path.dirname(repo.git_dir) orelse return false;
            return !std.mem.eql(u8, std.Io.Dir.path.basename(repo.git_dir), ".git") or std.mem.eql(u8, parent, repo.work_tree);
        },
        else => return false,
    }
}

/// Whether `path` is `root` or inside it; both absolute and resolved.
fn isWithin(root: []const u8, path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, root)) return false;
    return path.len == root.len or root[root.len - 1] == '/' or path[root.len] == '/';
}

/// `path` with every symlink resolved, or null when it cannot be resolved.
fn resolvedPath(arena: Allocator, path: []const u8) Allocator.Error!?[]const u8 {
    return io_mod.realpathAlloc(arena, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
}

/// The ref for `session_id` and the worktree whose git directory is
/// `git_dir`. The session part is a hash of the id, so any id fx accepts
/// fits git's ref rules and `safe_git`'s two-segment ref check.
fn sessionRefName(arena: Allocator, session_id: []const u8, git_dir: []const u8) Allocator.Error![]const u8 {
    return arena.print("refs/fx/sessions/{s}/{s}", .{ try sessionKey(arena, session_id), try pathKey(arena, git_dir) });
}

/// The ref segment that names `session_id`: the first 16 bytes of its
/// SHA-256, in hex. Retention matches sessions to refs with it.
pub fn sessionKey(arena: Allocator, session_id: []const u8) Allocator.Error![]const u8 {
    return pathKey(arena, session_id);
}

pub fn pastDeadline(io: std.Io, deadline: std.Io.Clock.Timestamp) bool {
    return deadline.compare(.lte, .now(io, deadline.clock));
}

fn ensurePrivateDir(io: std.Io, path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, path);
    var dir = try std.Io.Dir.openDirAbsolute(io, path, .{});
    defer dir.close(io);
    try dir.setPermissions(io, .fromMode(0o700));
}

/// fx's session id rule (`src/core/session_manager/schema.zig` `validId`).
fn validSessionId(id: []const u8) bool {
    if (id.len == 0 or id.len > 255 or id[0] == '.') return false;
    for (id) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '-', '_' => {},
        else => return false,
    };
    return true;
}

fn withFailure(base: Outcome, status: Status, reason: policy.Reason) Outcome {
    var outcome = base;
    outcome.status = status;
    outcome.reason = reason;
    outcome.tree = null;
    outcome.commit = null;
    return outcome;
}

fn withGitFailure(base: Outcome, failure: safe_git.Failure) Outcome {
    return switch (failure) {
        .timeout => withFailure(base, .unavailable, .timeout),
        .cancelled => withFailure(base, .unavailable, .cancelled),
        .path_rejected => withFailure(base, .failed, .inconsistent),
        .spawn_failed, .input_failed, .read_failed, .output_too_large, .exited_nonzero, .terminated => withFailure(base, .failed, .io_error),
    };
}

/// A failure observed after the shared deadline passed is a timeout.
fn deadlineOr(io: std.Io, deadline: std.Io.Clock.Timestamp, outcome: Outcome) Outcome {
    if (pastDeadline(io, deadline)) return withFailure(outcome, .unavailable, .timeout);
    return outcome;
}

/// Runs a store command and returns its output. Every argument comes from
/// git's own listings or validated input, so a rejected argument means the
/// listing and the store disagree.
pub fn storeOutput(arena: Allocator, ready: safe_git.StoreReady, store: safe_git.Store, command: safe_git.StoreCommand, limits: safe_git.Limits) Allocator.Error!safe_git.Outcome {
    return safe_git.runStore(arena, ready, store, command, limits) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidArgument => return .{ .failed = .path_rejected },
    };
}

/// Runs a store command whose output is not needed; null on success.
fn runStore(arena: Allocator, ready: safe_git.StoreReady, store: safe_git.Store, command: safe_git.StoreCommand, limits: safe_git.Limits) Allocator.Error!?safe_git.Failure {
    return switch (try storeOutput(arena, ready, store, command, limits)) {
        .ok => null,
        .failed => |failure| failure,
    };
}

/// The reason for a partial capture: the most telling exclusion that loses
/// content, whatever the paths' order. A file that vanished mid-capture
/// shows concurrent change, so it outranks limits, which outrank secrets,
/// which outrank submodules.
fn lossReason(excluded: []const policy.Exclusion) ?policy.Reason {
    const ranked = [_]struct { policy.Reason, @FieldType(policy.Exclusion, "reason") }{
        .{ .inconsistent, .missing },
        .{ .too_large, .too_large },
        .{ .file_limit, .file_limit },
        .{ .sensitive, .sensitive },
        .{ .submodule, .submodule },
    };
    var best: ?usize = null;
    for (excluded) |entry| {
        for (ranked, 0..) |rank, i| {
            if (entry.reason == rank[1] and (best == null or i < best.?)) best = i;
        }
    }
    return if (best) |i| ranked[i][0] else null;
}

pub const EncodeError = Allocator.Error || error{InvalidOutcome};

/// Excluded paths the record names one by one; the rest are only counted.
const max_sample_paths = 32;
const max_sample_bytes = 32 * 1024;

const ExclusionReason = @FieldType(policy.Exclusion, "reason");

/// The session's `workspace_capture` item for `outcome` at `phase`, as one
/// line of JSON (D98). Exclusions are counted by reason with a bounded
/// sample, so the item stays far below the 256 KiB a session item allows
/// however many paths a capture leaves out; a path that is not UTF-8 is
/// written as hex. Fails with `InvalidOutcome` when the outcome contradicts
/// itself. Returns owned bytes; the caller frees them.
pub fn encodeRecord(alloc: Allocator, phase: Phase, outcome: Outcome) EncodeError![]u8 {
    try checkOutcome(outcome);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var by_reason: Counts = .{};
    var sample: std.ArrayList(Sample) = .empty;
    var sample_bytes: usize = 0;
    var truncated = false;
    for (outcome.excluded) |entry| {
        switch (entry.reason) {
            .sensitive => by_reason.sensitive += 1,
            .too_large => by_reason.too_large += 1,
            .file_limit => by_reason.file_limit += 1,
            .missing => by_reason.missing += 1,
            .submodule => by_reason.submodule += 1,
        }
        const utf8 = std.unicode.utf8ValidateSlice(entry.path);
        const cost = if (utf8) entry.path.len else entry.path.len * 2;
        if (sample.items.len == max_sample_paths or sample_bytes + cost > max_sample_bytes) {
            truncated = true;
            continue;
        }
        sample_bytes += cost;
        try sample.append(arena, if (utf8)
            .{ .path = entry.path, .reason = entry.reason }
        else
            .{ .path_hex = try arena.print("{x}", .{entry.path}), .reason = entry.reason });
    }
    const record: RecordJson = .{
        .phase = phase,
        .status = outcome.status,
        .reason = outcome.reason,
        .work_tree = if (outcome.repository) |repo| repo.work_tree else null,
        .ref = outcome.ref,
        .head_state = outcome.head,
        .head = switch (outcome.head) {
            .commit => |oid| oid,
            else => null,
        },
        .tree = outcome.tree,
        .commit = outcome.commit,
        .object_format = outcome.object_format,
        .listing = outcome.listing,
        .index = outcome.index,
        .comparable = outcome.comparable,
        .trigger_tool = outcome.trigger_tool,
        .excluded = .{ .total = outcome.excluded.len, .by_reason = by_reason, .sample = sample.items, .sample_truncated = truncated },
    };
    var writer: std.Io.Writer.Allocating = .init(alloc);
    defer writer.deinit();
    std.json.Stringify.value(record, .{}, &writer.writer) catch return error.OutOfMemory;
    return writer.toOwnedSlice();
}

const RecordJson = struct {
    v: u8 = 1,
    phase: Phase,
    status: Status,
    reason: ?policy.Reason,
    work_tree: ?[]const u8,
    ref: ?[]const u8,
    head_state: std.meta.Tag(Head),
    head: ?[]const u8,
    tree: ?[]const u8,
    commit: ?[]const u8,
    object_format: ?safe_git.ObjectFormat,
    listing: ?Listing,
    index: ?IndexStart,
    comparable: bool,
    trigger_tool: ?[]const u8,
    excluded: struct {
        total: usize,
        by_reason: Counts,
        sample: []const Sample,
        sample_truncated: bool,
    },
};

const Counts = struct {
    sensitive: usize = 0,
    too_large: usize = 0,
    file_limit: usize = 0,
    missing: usize = 0,
    submodule: usize = 0,
};

const Sample = struct {
    path: ?[]const u8 = null,
    path_hex: ?[]const u8 = null,
    reason: ExclusionReason,
};

/// Rejects an outcome whose status, reason and object IDs disagree, so a
/// record never claims a tree for a failure or a reason the status rules out.
fn checkOutcome(outcome: Outcome) error{InvalidOutcome}!void {
    switch (outcome.status) {
        .complete => if (outcome.reason != null or outcome.tree == null or outcome.commit == null) return error.InvalidOutcome,
        .partial => if (outcome.reason == null or outcome.tree == null or outcome.commit == null) return error.InvalidOutcome,
        .failed, .unavailable => if (outcome.reason == null or outcome.tree != null or outcome.commit != null) return error.InvalidOutcome,
    }
    if (outcome.reason) |reason| {
        const allowed = switch (reason) {
            .sensitive, .too_large, .file_limit, .submodule => outcome.status == .partial,
            .timeout, .not_git, .git_refused, .index_sparse, .capture_locked, .foreign_git_dir, .host_unsupported, .cancelled => outcome.status == .unavailable,
            .budget, .untracked_timeout => outcome.status == .partial or outcome.status == .unavailable,
            .inconsistent => outcome.status == .partial or outcome.status == .failed,
            .io_error, .invalid_request => outcome.status == .failed,
        };
        if (!allowed) return error.InvalidOutcome;
    }
    const oids = [_]?[]const u8{ outcome.tree, outcome.commit, switch (outcome.head) {
        .commit => |oid| oid,
        else => null,
    } };
    for (oids) |maybe| if (maybe) |oid| {
        const format = outcome.object_format orelse return error.InvalidOutcome;
        if (!safe_git.isOid(oid, format)) return error.InvalidOutcome;
    };
}

const Lock = struct {
    file: std.Io.File,

    fn close(self: *Lock, io: std.Io) void {
        self.file.close(io);
    }
};

/// Takes the worktree's lock, waiting for another capture of the same
/// worktree, such as a parallel subagent's, until `deadline`.
fn acquireLock(io: std.Io, path: []const u8, deadline: std.Io.Clock.Timestamp) error{ Busy, Unavailable }!Lock {
    const file = std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = false, .read = true }) catch return error.Unavailable;
    errdefer file.close(io);
    while (!(file.tryLock(io, .exclusive) catch return error.Unavailable)) {
        if (pastDeadline(io, deadline)) return error.Busy;
        io_mod.sleep(10 * std.time.ns_per_ms);
    }
    return .{ .file = file };
}

pub fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

fn hasSharedIndex(io: std.Io, git_dir: []const u8) Allocator.Error!bool {
    // When the folder cannot be read, assume a split index: rebuilding from
    // HEAD is always correct, a copy of a split index is not.
    var dir = std.Io.Dir.openDirAbsolute(io, git_dir, .{ .iterate = true }) catch return true;
    defer dir.close(io);
    var entries = dir.iterate();
    while (entries.next(io) catch return true) |entry| {
        if (std.mem.startsWith(u8, entry.name, "sharedindex.")) return true;
    }
    return false;
}

/// Makes sure the store exists with alternates into the user's objects. It is
/// built under a temporary name and renamed into place, so a store is either
/// absent or complete: a crash between `git init` and the alternates can never
/// leave a store that cannot read the user's objects. Everything happens under
/// a store-wide lock shared by the repository's worktrees. Null on success.
fn ensureStore(
    arena: Allocator,
    io: std.Io,
    ready: safe_git.StoreReady,
    store_dir: []const u8,
    git_dir: []const u8,
    common_dir: []const u8,
    format: safe_git.ObjectFormat,
    limits: safe_git.Limits,
    deadline: std.Io.Clock.Timestamp,
) Allocator.Error!?safe_git.Failure {
    const init_lock_path = try std.Io.Dir.path.join(arena, &.{ store_dir, "init.lock" });
    const init_lock = std.Io.Dir.createFileAbsolute(io, init_lock_path, .{ .truncate = false, .read = true }) catch return .read_failed;
    defer init_lock.close(io);
    while (!(init_lock.tryLock(io, .exclusive) catch return .read_failed)) {
        if (pastDeadline(io, deadline)) return .timeout;
        io_mod.sleep(10 * std.time.ns_per_ms);
    }
    const alternates_line = try arena.print("{s}\n", .{try std.Io.Dir.path.join(arena, &.{ common_dir, "objects" })});
    if (exists(io, try std.Io.Dir.path.join(arena, &.{ git_dir, "HEAD" }))) {
        // A store from before atomic creation may lack its alternates.
        const alternates = try std.Io.Dir.path.join(arena, &.{ git_dir, "objects", "info", "alternates" });
        if (!exists(io, alternates)) writeAlternates(io, alternates, alternates_line) catch return .read_failed;
        return null;
    }
    // A store folder without HEAD is a removal that stopped halfway; move it
    // aside so the rename below finds the name free.
    if (exists(io, git_dir)) {
        const aside = try arena.print("{s}.tmp-aside-{d}", .{ git_dir, io_mod.nanoTimestamp() });
        std.Io.Dir.renameAbsolute(git_dir, aside, io) catch return .read_failed;
    }
    removeTemporaryStores(io, store_dir);
    const temporary = try arena.print("{s}.tmp-{d}", .{ git_dir, io_mod.nanoTimestamp() });
    switch (safe_git.initStore(arena, ready, temporary, format, limits) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidArgument => return .spawn_failed,
    }) {
        .ok => {},
        .failed => |failure| return failure,
    }
    const info = try std.Io.Dir.path.join(arena, &.{ temporary, "objects", "info" });
    std.Io.Dir.cwd().createDirPath(io, info) catch return .read_failed;
    writeAlternates(io, try std.Io.Dir.path.join(arena, &.{ info, "alternates" }), alternates_line) catch return .read_failed;
    ensurePrivateDir(io, temporary) catch return .read_failed;
    std.Io.Dir.renameAbsolute(temporary, git_dir, io) catch return .read_failed;
    return null;
}

fn writeAlternates(io: std.Io, path: []const u8, line: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = line, .flags = .{ .permissions = .fromMode(0o600) } });
}

/// Deletes stores a crash left half built. Called under the store lock.
fn removeTemporaryStores(io: std.Io, store_dir: []const u8) void {
    var dir = std.Io.Dir.openDirAbsolute(io, store_dir, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var entries = dir.iterate();
    while (entries.next(io) catch return) |entry| {
        if (entry.kind == .directory and std.mem.startsWith(u8, entry.name, "store.git.tmp-")) {
            dir.deleteTree(io, entry.name) catch {};
        }
    }
}

/// Copies `from` to `to` through a temporary file and gives the copy the
/// original's modification time.
fn copyPreservingTime(arena: Allocator, io: std.Io, from: []const u8, to: []const u8) !void {
    var source = try std.Io.Dir.openFileAbsolute(io, from, .{});
    defer source.close(io);
    const stat = try source.stat(io);
    const bytes = try io_mod.readFileToEnd(arena, &source, max_index_bytes);
    const temporary = try arena.print("{s}.tmp", .{to});
    {
        var copy = try std.Io.Dir.createFileAbsolute(io, temporary, .{});
        defer copy.close(io);
        try copy.writeStreamingAll(io, bytes);
        try copy.setTimestamps(io, .{ .modify_timestamp = .{ .new = stat.mtime } });
    }
    try std.Io.Dir.renameAbsolute(temporary, to, io);
}

const max_index_bytes: usize = 1 << 30;

const Staged = safe_git.StagedEntry;

const Untracked = struct {
    files: []const []const u8,
    /// Folders holding their own repository, which git never enters.
    nested: []const []const u8,
};

const UntrackedListing = union(enum) {
    listed: Untracked,
    /// The deadline passed before a listing finished.
    stopped,
    /// No listing could be made.
    failed,
};

/// Untracked paths relative to the worktree root. Both listings stop at
/// `deadline`. Records the source in `outcome.listing`.
fn listUntracked(
    arena: Allocator,
    scan_allocator: Allocator,
    ready: safe_git.Ready,
    facts: safe_git.RepositoryFacts,
    deadline: std.Io.Clock.Timestamp,
    tracked: *const std.StringHashMapUnmanaged(Staged),
    outcome: *Outcome,
) Allocator.Error!UntrackedListing {
    const io = io_mod.getIo();
    if (pastDeadline(io, deadline)) return .stopped;
    // Where git compares paths without case, a case-only rename shows up as
    // a new untracked spelling of a tracked file; git does not list it.
    var folded: std.StringHashMapUnmanaged(void) = .empty;
    if (facts.ignore_case) {
        var it = tracked.keyIterator();
        while (it.next()) |path| try folded.put(arena, try std.ascii.allocLowerString(arena, path.*), {});
    }
    var files: std.ArrayList([]const u8) = .empty;
    var nested: std.ArrayList([]const u8) = .empty;
    native: {
        // The indexer reads no clock: a task raises its stop flag at the
        // deadline. Without a task to do that, git lists instead, since its
        // run stops at the deadline itself.
        var stop: std.atomic.Value(bool) = .init(false);
        var watch = std.Io.concurrent(io, stopAtDeadline, .{ io, deadline, &stop }) catch break :native;
        defer watch.cancel(io);
        var result = indexer.scan(scan_allocator, facts.work_tree, .{ .candidate_cap = max_listed_paths }, &stop) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => if (stop.load(.acquire)) return .stopped else break :native,
            error.RootUnavailable => break :native,
        };
        defer result.deinit();
        if (pastDeadline(io, deadline)) return .stopped;
        const listing = result.tree;
        // Anything the indexer left out sends the listing to git.
        if (listing.incomplete or listing.cap_reached or listing.skipped_overlong > 0 or !listing.repository) break :native;
        // A folder the indexer listed but did not enter holds its own
        // repository, exactly where git stops too.
        for (listing.folders) |folder| {
            if (folder.boundary and !tracked.contains(folder.rel)) try nested.append(arena, try arena.dupe(u8, folder.rel));
        }
        for (listing.entries, 0..) |entry, i| {
            if (i % 4096 == 4095 and pastDeadline(io, deadline)) return .stopped;
            if (tracked.contains(entry.path)) continue;
            // The indexer lists file names as the folder stores them; with
            // precomposed Unicode git compares another form of those names.
            if (facts.precompose_unicode and !isAscii(entry.path)) {
                files.clearRetainingCapacity();
                nested.clearRetainingCapacity();
                break :native;
            }
            switch (entry.kind) {
                .file => {
                    if (facts.ignore_case and folded.contains(try std.ascii.allocLowerString(arena, entry.path))) continue;
                    try files.append(arena, try arena.dupe(u8, entry.path));
                },
                .directory => {},
            }
        }
        outcome.listing = .indexer;
        return .{ .listed = .{ .files = files.items, .nested = nested.items } };
    }
    // git starts only while time remains.
    if (pastDeadline(io, deadline)) return .stopped;
    const listing = switch (try safe_git.listRepository(arena, ready, facts.work_tree, .untracked, .{ .deadline = deadline })) {
        .ok => |stdout| stdout,
        .failed => |failure| return if (failure == .timeout) .stopped else .failed,
    };
    var records = std.mem.splitScalar(u8, listing, 0);
    while (records.next()) |record| {
        if (record.len == 0) continue;
        // git lists a nested repository once, as a folder with a slash.
        if (record[record.len - 1] == '/') {
            try nested.append(arena, record[0 .. record.len - 1]);
        } else {
            try files.append(arena, record);
        }
    }
    outcome.listing = .git;
    return .{ .listed = .{ .files = files.items, .nested = nested.items } };
}

/// Raises `stop` once `deadline` passes, unless cancelled first.
fn stopAtDeadline(io: std.Io, deadline: std.Io.Clock.Timestamp, stop: *std.atomic.Value(bool)) void {
    deadline.wait(io) catch return;
    stop.store(true, .release);
}

fn isAscii(text: []const u8) bool {
    for (text) |c| if (c >= 0x80) return false;
    return true;
}

const max_listed_paths: usize = 1_000_000;

const Found = struct {
    present: bool,
    bytes: u64 = 0,
    kind: @FieldType(policy.Candidate, "kind") = .file,
};

const not_on_disk: Found = .{ .present = false };

/// What the disk holds at worktree paths, without following symlinks at any
/// level: a path under a symlinked folder is absent, as git sees it.
const Disk = struct {
    arena: Allocator,
    io: std.Io,
    work_tree: []const u8,
    /// Parent folders already checked: true when a real folder.
    parents: std.StringHashMapUnmanaged(bool) = .empty,

    /// Fails only when the disk cannot answer, such as a folder without read
    /// permission; a missing path is `absent`.
    fn lstat(self: *Disk, path: []const u8) (Allocator.Error || error{Unreadable})!Found {
        var end: usize = 0;
        while (std.mem.findScalarPos(u8, path, end, '/')) |slash| : (end = slash + 1) {
            const parent = path[0..slash];
            const real = self.parents.get(parent) orelse blk: {
                const found = try self.statOne(parent);
                const is_dir = found.present and found.kind == .gitlink;
                try self.parents.put(self.arena, parent, is_dir);
                break :blk is_dir;
            };
            if (!real) return not_on_disk;
        }
        return self.statOne(path);
    }

    fn statOne(self: *Disk, path: []const u8) (Allocator.Error || error{Unreadable})!Found {
        const absolute = try std.Io.Dir.path.join(self.arena, &.{ self.work_tree, path });
        const stat = std.Io.Dir.cwd().statFile(self.io, absolute, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return not_on_disk,
            else => return error.Unreadable,
        };
        return switch (stat.kind) {
            .sym_link => .{ .present = true, .bytes = stat.size, .kind = .symlink },
            .file => .{ .present = true, .bytes = stat.size, .kind = .file },
            // Callers decide what a folder means: a gitlink, or a gone file.
            .directory => .{ .present = true, .kind = .gitlink },
            // git records neither pipes, sockets nor devices.
            else => not_on_disk,
        };
    }
};

/// The directory for the repository whose common git directory is
/// `common_dir`: it holds the bare store (`storeGitDir`) and, beside it, one
/// directory per worktree. The worktree directories stay outside the bare
/// repository because git reserves its `worktrees/` folder and `git gc` prunes
/// it. Owned by `arena`.
fn storeDir(arena: Allocator, profile_root: []const u8, common_dir: []const u8) Allocator.Error![]const u8 {
    return std.Io.Dir.path.join(arena, &.{ profile_root, "captures", try pathKey(arena, common_dir) });
}

/// The bare store inside a repository's `storeDir`. Owned by `arena`.
pub fn storeGitDir(arena: Allocator, store_dir: []const u8) Allocator.Error![]const u8 {
    return std.Io.Dir.path.join(arena, &.{ store_dir, "store.git" });
}

/// The directory that holds one worktree's capture index, lock and scratch
/// files inside its repository's store directory. Owned by `arena`.
fn worktreeDir(arena: Allocator, store_dir: []const u8, git_dir: []const u8) Allocator.Error![]const u8 {
    return std.Io.Dir.path.join(arena, &.{ store_dir, "worktrees", try pathKey(arena, git_dir) });
}

fn pathKey(arena: Allocator, path: []const u8) Allocator.Error![]const u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(path, &digest, .{});
    return arena.print("{x}", .{digest[0..16]});
}

pub const CopyRequest = struct {
    /// The fx profile root, such as `~/.fx`.
    profile_root: []const u8,
    /// The session whose captures are copied. Its refs are only read.
    from_session_id: []const u8,
    /// The session that receives them, such as a fork of `from_session_id`.
    to_session_id: []const u8,
    /// One budget for every store.
    deadline: std.Io.Clock.Timestamp,
};

/// What `copySessionRefs` did, counted in refs and stores.
pub const CopyResult = struct {
    /// Refs created for the receiving session.
    copied: usize = 0,
    /// Refs the receiving session already had at the same commit, such as
    /// from an earlier copy.
    existing: usize = 0,
    /// Refs the receiving session already had at another commit, which stay
    /// as they are.
    conflicting: usize = 0,
    /// Stores that could not be read or written, or stayed locked past the
    /// deadline; refs not copied from them are not counted.
    failed_stores: usize = 0,
};

pub const CopyError = Allocator.Error || error{InvalidRequest};

/// Gives `to_session_id` every capture `from_session_id` has, for a fork:
/// each of the first session's refs, in every repository's store, gets a
/// twin under the second session's key that names the same commit, so the
/// fork's captures stay when the original's are evicted. It only creates
/// refs, never moves or deletes one, so the first session's refs are never
/// touched and a second run changes nothing. Each store is handled under its
/// `init.lock`, which pruning holds, so no commit is pruned between listing
/// it and naming it. Memory belongs to `arena`.
pub fn copySessionRefs(arena: Allocator, request: CopyRequest) CopyError!CopyResult {
    if (!validSessionId(request.from_session_id) or !validSessionId(request.to_session_id) or
        std.mem.eql(u8, request.from_session_id, request.to_session_id) or
        !std.Io.Dir.path.isAbsolute(request.profile_root)) return error.InvalidRequest;
    const io = io_mod.getIo();
    var result: CopyResult = .{};
    const stores = try listStoreDirs(arena, io, try std.Io.Dir.path.join(arena, &.{ request.profile_root, "captures" }));
    if (stores.len == 0) return result;
    const limits: safe_git.Limits = .{ .deadline = request.deadline };
    const ready = switch (try safe_git.prepareStore(arena, limits)) {
        .ready => |value| value,
        .refused => {
            result.failed_stores = stores.len;
            return result;
        },
    };
    const from_prefix = try arena.print("refs/fx/sessions/{s}/", .{try sessionKey(arena, request.from_session_id)});
    const to_key = try sessionKey(arena, request.to_session_id);
    for (stores) |store_dir| {
        if (!try copyStoreRefs(arena, io, ready, store_dir, from_prefix, to_key, request.deadline, &result)) result.failed_stores += 1;
    }
    return result;
}

/// Copies the refs under `from_prefix` in one store to `to_key`. False when
/// the store could not be locked, listed or written.
fn copyStoreRefs(
    arena: Allocator,
    io: std.Io,
    ready: safe_git.StoreReady,
    store_dir: []const u8,
    from_prefix: []const u8,
    to_key: []const u8,
    deadline: std.Io.Clock.Timestamp,
    result: *CopyResult,
) Allocator.Error!bool {
    const lock = std.Io.Dir.createFileAbsolute(io, try std.Io.Dir.path.join(arena, &.{ store_dir, "init.lock" }), .{ .truncate = false, .read = true }) catch return false;
    defer lock.close(io);
    while (!(lock.tryLock(io, .exclusive) catch return false)) {
        if (pastDeadline(io, deadline)) return false;
        io_mod.sleep(10 * std.time.ns_per_ms);
    }
    const limits: safe_git.Limits = .{ .deadline = deadline };
    const store = try refStore(arena, store_dir);
    const listing = switch (try storeOutput(arena, ready, store, .list_refs, limits)) {
        .ok => |stdout| stdout,
        .failed => return false,
    };
    // Each line is `<ref> <object> <unix seconds>`.
    const Source = struct { worktree: []const u8, oid: []const u8 };
    var sources: std.ArrayList(Source) = .empty;
    var present: std.StringHashMapUnmanaged([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ' ');
        const name = fields.next() orelse continue;
        const oid = fields.next() orelse continue;
        if (std.mem.startsWith(u8, name, from_prefix)) {
            const worktree = name[from_prefix.len..];
            if (worktree.len == 0 or std.mem.findScalar(u8, worktree, '/') != null) continue;
            try sources.append(arena, .{ .worktree = worktree, .oid = oid });
        } else {
            try present.put(arena, name, oid);
        }
    }
    for (sources.items) |source| {
        const target = try arena.print("refs/fx/sessions/{s}/{s}", .{ to_key, source.worktree });
        if (present.get(target)) |oid| {
            if (std.mem.eql(u8, oid, source.oid)) result.existing += 1 else result.conflicting += 1;
            continue;
        }
        // A null `old` creates the ref only if it does not exist yet.
        switch (try storeOutput(arena, ready, store, .{ .update_ref = .{ .ref = target, .new = source.oid, .old = null } }, limits)) {
            .ok => result.copied += 1,
            .failed => return false,
        }
    }
    return true;
}

/// A store's git directory for ref commands, which touch neither an index
/// nor a worktree; git still needs both names, so they point inside the
/// store's folder.
fn refStore(arena: Allocator, store_dir: []const u8) Allocator.Error!safe_git.Store {
    return .{
        .git_dir = try storeGitDir(arena, store_dir),
        .index_file = try std.Io.Dir.path.join(arena, &.{ store_dir, "refs.index" }),
        .work_tree = store_dir,
        .scratch_dir = store_dir,
    };
}

/// The repository folders under `captures` whose store is complete, in name
/// order.
fn listStoreDirs(arena: Allocator, io: std.Io, captures: []const u8) Allocator.Error![]const []const u8 {
    var stores: std.ArrayList([]const u8) = .empty;
    var dir = std.Io.Dir.openDirAbsolute(io, captures, .{ .iterate = true }) catch return stores.items;
    defer dir.close(io);
    var entries = dir.iterate();
    while (entries.next(io) catch null) |entry| {
        if (entry.kind != .directory or entry.name.len != 32) continue;
        const store_dir = try std.Io.Dir.path.join(arena, &.{ captures, entry.name });
        if (exists(io, try std.Io.Dir.path.join(arena, &.{ store_dir, "store.git", "HEAD" }))) try stores.append(arena, store_dir);
    }
    sort_utils.sort([]const u8, stores.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    return stores.items;
}

/// The store-wide lock a capture holds from before it writes the store's
/// first object (`ensureStore`). Owned by `arena`.
pub fn initLockPath(arena: Allocator, store_dir: []const u8) Allocator.Error![]const u8 {
    return std.Io.Dir.path.join(arena, &.{ store_dir, "init.lock" });
}

/// The folder that holds every `worktreeDir` of a store. Owned by `arena`.
pub fn worktreesDir(arena: Allocator, store_dir: []const u8) Allocator.Error![]const u8 {
    return std.Io.Dir.path.join(arena, &.{ store_dir, "worktrees" });
}

/// The file names of a worktree directory's capture lock and capture index.
pub const worktree_lock_name = "lock";
pub const worktree_index_name = "index";

// ---- Tests below this line ----

const builtin = @import("builtin");
const testing = std.testing;

/// Plain git for fixtures and oracles. The capture itself finds its own git.
const test_git = "/usr/bin/git";
const test_unix_seconds: i64 = 1_700_000_000;
const test_deadline_ms: i64 = 20_000;
const fixture_identity = [_][]const u8{ "-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid" };
/// Programs a repository could name stay off in oracles and probes.
const oracle_overrides = [_][]const u8{ "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null" };

const EnvPair = struct { []const u8, []const u8 };

/// Real repositories under one temporary folder. fx's environment, which
/// `safe_git.environment()` reads through `io_mod.getenv`, and the fixtures'
/// git both point HOME and the global config at files inside it and turn the
/// system config off, so neither the developer's nor the machine's git config
/// reaches a test. The global config has no identity: capture commits must
/// not depend on one.
const TestRepos = struct {
    arena: Allocator,
    root: []const u8,
    home: []const u8,
    profile: []const u8,
    global_config: []const u8,
    sentinel: []const u8,
    sentinel_log: []const u8,
    env: *std.process.Environ.Map,

    fn init(arena: Allocator, dir: std.Io.Dir) !TestRepos {
        if (builtin.target.os.tag == .windows) return error.SkipZigTest;
        std.Io.Dir.accessAbsolute(testing.io, test_git, .{}) catch return error.SkipZigTest;
        switch (try safe_git.prepareStore(arena, .{})) {
            .ready => {},
            .refused => return error.SkipZigTest,
        }
        const root = try io_mod.dirRealpathAlloc(arena, dir, ".");
        const home = try std.Io.Dir.path.join(arena, &.{ root, "home" });
        const env = try arena.create(std.process.Environ.Map);
        env.* = std.process.Environ.Map.init(arena);
        const self: TestRepos = .{
            .arena = arena,
            .root = root,
            .home = home,
            .profile = try std.Io.Dir.path.join(arena, &.{ root, "profile" }),
            .global_config = try std.Io.Dir.path.join(arena, &.{ home, ".gitconfig" }),
            .sentinel = try std.Io.Dir.path.join(arena, &.{ root, "sentinel.sh" }),
            .sentinel_log = try std.Io.Dir.path.join(arena, &.{ root, "sentinel.log" }),
            .env = env,
        };
        try std.Io.Dir.cwd().createDirPath(testing.io, home);
        try std.Io.Dir.cwd().createDirPath(testing.io, self.profile);
        try writeAbsolute(self.global_config, "[init]\n\tdefaultBranch = main\n[protocol \"file\"]\n\tallow = always\n");
        try env.put("HOME", home);
        try env.put("XDG_CONFIG_HOME", try std.Io.Dir.path.join(arena, &.{ home, ".config" }));
        try env.put("GIT_CONFIG_GLOBAL", self.global_config);
        try env.put("GIT_CONFIG_NOSYSTEM", "1");
        if (!try self.fixtureGitSupported()) return error.SkipZigTest;
        io_mod.setEnvironMap(env);
        return self;
    }

    fn deinit(self: TestRepos) void {
        _ = self;
        io_mod.resetEnvironForTest();
    }

    /// The fixtures use `--path-format`, `init -b` and `--sparse-index`.
    fn fixtureGitSupported(self: TestRepos) !bool {
        const result = try self.run(self.root, &.{ test_git, "--version" }, &.{});
        switch (result.term) {
            .exited => |code| if (code != 0) return false,
            else => return false,
        }
        const prefix = "git version ";
        if (!std.mem.startsWith(u8, result.stdout, prefix)) return false;
        var parts = std.mem.splitScalar(u8, std.mem.trimEnd(u8, result.stdout[prefix.len..], "\n"), '.');
        const major = std.fmt.parseInt(u32, parts.next() orelse return false, 10) catch return false;
        const minor_text = parts.next() orelse return false;
        var end: usize = 0;
        while (end < minor_text.len and std.ascii.isDigit(minor_text[end])) end += 1;
        const minor = std.fmt.parseInt(u32, minor_text[0..end], 10) catch return false;
        return major > 2 or (major == 2 and minor >= 32);
    }

    fn path(self: TestRepos, sub_path: []const u8) ![]const u8 {
        return std.Io.Dir.path.join(self.arena, &.{ self.root, sub_path });
    }

    // Files, by path relative to the temporary folder.

    fn writeAbsolute(absolute: []const u8, data: []const u8) !void {
        if (std.Io.Dir.path.dirname(absolute)) |parent| try std.Io.Dir.cwd().createDirPath(testing.io, parent);
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = absolute, .data = data });
    }

    fn write(self: TestRepos, sub_path: []const u8, data: []const u8) !void {
        try writeAbsolute(try self.path(sub_path), data);
    }

    fn append(self: TestRepos, sub_path: []const u8, data: []const u8) !void {
        const old = self.read(sub_path) catch |err| switch (err) {
            error.FileNotFound => "",
            else => return err,
        };
        try self.write(sub_path, try std.mem.concat(self.arena, u8, &.{ old, data }));
    }

    fn read(self: TestRepos, sub_path: []const u8) ![]const u8 {
        return readAbsolute(self.arena, try self.path(sub_path));
    }

    fn readAbsolute(arena: Allocator, absolute: []const u8) ![]const u8 {
        return std.Io.Dir.cwd().readFileAlloc(testing.io, absolute, arena, .limited(64 * 1024 * 1024));
    }

    fn chmod(self: TestRepos, sub_path: []const u8, mode: std.posix.mode_t) !void {
        try std.Io.Dir.cwd().setFilePermissions(testing.io, try self.path(sub_path), .fromMode(mode), .{});
    }

    fn remove(self: TestRepos, sub_path: []const u8) !void {
        try std.Io.Dir.deleteFileAbsolute(testing.io, try self.path(sub_path));
    }

    fn rename(self: TestRepos, old: []const u8, new: []const u8) !void {
        try std.Io.Dir.renameAbsolute(try self.path(old), try self.path(new), testing.io);
    }

    fn symlink(self: TestRepos, target: []const u8, sub_path: []const u8) !void {
        try std.Io.Dir.cwd().symLink(testing.io, target, try self.path(sub_path), .{});
    }

    fn exists(self: TestRepos, sub_path: []const u8) !bool {
        return existsAbsolute(try self.path(sub_path));
    }

    fn existsAbsolute(absolute: []const u8) !bool {
        _ = std.Io.Dir.cwd().statFile(testing.io, absolute, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return true;
    }

    fn deleteIfPresent(absolute: []const u8) !void {
        std.Io.Dir.deleteFileAbsolute(testing.io, absolute) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    fn setModified(self: TestRepos, sub_path: []const u8, unix_seconds: i64) !void {
        const at: std.Io.Timestamp = .{ .nanoseconds = @as(i96, unix_seconds) * std.time.ns_per_s };
        try std.Io.Dir.cwd().setTimestamps(testing.io, try self.path(sub_path), .{ .access_timestamp = .{ .new = at }, .modify_timestamp = .{ .new = at } });
    }

    /// Like `cp -p`: the copy keeps the source's modification time, so git's
    /// racy-timestamp check behaves as it does on the original index.
    fn copyKeepingTime(self: TestRepos, source: []const u8, dest: []const u8) !void {
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = dest, .data = try readAbsolute(self.arena, source) });
        const stat = try std.Io.Dir.cwd().statFile(testing.io, source, .{});
        try std.Io.Dir.cwd().setTimestamps(testing.io, dest, .{ .access_timestamp = .init(stat.atime), .modify_timestamp = .{ .new = stat.mtime } });
    }

    fn randomBytes(self: TestRepos, len: usize, seed: u64) ![]const u8 {
        const bytes = try self.arena.alloc(u8, len);
        var prng = std.Random.DefaultPrng.init(seed);
        prng.random().bytes(bytes);
        return bytes;
    }

    // Processes.

    fn run(self: TestRepos, cwd: []const u8, argv: []const []const u8, extra: []const EnvPair) !std.process.RunResult {
        var env = std.process.Environ.Map.init(self.arena);
        try env.put("PATH", "/usr/bin:/bin");
        try env.put("LC_ALL", "C");
        try env.put("GIT_TERMINAL_PROMPT", "0");
        // A fixture command never climbs out of the temporary folder into the
        // checkout that holds it.
        try env.put("GIT_CEILING_DIRECTORIES", self.root);
        var keys = self.env.iterator();
        while (keys.next()) |entry| try env.put(entry.key_ptr.*, entry.value_ptr.*);
        for (extra) |pair| try env.put(pair[0], pair[1]);
        return std.process.run(self.arena, testing.io, .{
            .argv = argv,
            .cwd = .{ .path = cwd },
            .environ_map = &env,
            .stdout_limit = .limited(16 * 1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
        });
    }

    fn gitArgv(self: TestRepos, args: []const []const u8) ![]const []const u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(self.arena, test_git);
        try argv.appendSlice(self.arena, args);
        return argv.items;
    }

    /// Runs plain git and returns its trimmed stdout. Any failure fails the
    /// fixture, never the capture under test, and prints git's stderr.
    fn gitEnv(self: TestRepos, cwd: []const u8, args: []const []const u8, extra: []const EnvPair) ![]const u8 {
        const result = try self.run(cwd, try self.gitArgv(args), extra);
        switch (result.term) {
            .exited => |code| if (code == 0) return std.mem.trimEnd(u8, result.stdout, "\n"),
            else => {},
        }
        std.debug.print("fixture git", .{});
        for (args) |arg| std.debug.print(" {s}", .{arg});
        std.debug.print(" failed in {s}: {s}\n", .{ cwd, result.stderr });
        return error.FixtureGitFailed;
    }

    fn git(self: TestRepos, cwd: []const u8, args: []const []const u8) ![]const u8 {
        return self.gitEnv(cwd, args, &.{});
    }

    fn gitIn(self: TestRepos, sub_path: []const u8, args: []const []const u8) ![]const u8 {
        return self.git(try self.path(sub_path), args);
    }

    fn commit(self: TestRepos, sub_path: []const u8, message: []const u8) !void {
        _ = try self.gitIn(sub_path, &(fixture_identity ++ [_][]const u8{ "commit", "-q", "-m", message }));
    }

    fn commitAll(self: TestRepos, sub_path: []const u8, message: []const u8) !void {
        _ = try self.gitIn(sub_path, &(fixture_identity ++ [_][]const u8{ "commit", "-q", "-am", message }));
    }

    fn initRepo(self: TestRepos, sub_path: []const u8) !void {
        try std.Io.Dir.cwd().createDirPath(testing.io, try self.path(sub_path));
        _ = try self.gitIn(sub_path, &.{ "init", "-q", "-b", "main" });
    }

    /// The paths a capture reads, as git itself resolves them.
    fn repository(self: TestRepos, sub_path: []const u8) !Repository {
        const out = try self.gitIn(sub_path, &.{ "rev-parse", "--path-format=absolute", "--show-toplevel", "--git-dir", "--git-common-dir" });
        var lines = std.mem.splitScalar(u8, out, '\n');
        return .{
            .work_tree = lines.next() orelse return error.FixtureGitFailed,
            .git_dir = lines.next() orelse return error.FixtureGitFailed,
            .common_dir = lines.next() orelse return error.FixtureGitFailed,
        };
    }

    // Capture and store.

    fn request(self: TestRepos, repo: Repository, session_id: []const u8, limits: policy.Limits) Request {
        return .{
            .profile_root = self.profile,
            .path = repo.work_tree,
            .session_id = session_id,
            .phase = .start,
            .unix_seconds = test_unix_seconds,
            .deadline = .fromNow(testing.io, .{ .clock = .awake, .raw = .fromMilliseconds(test_deadline_ms) }),
            .limits = limits,
            .scan_allocator = testing.allocator,
        };
    }

    fn captureRepo(self: TestRepos, repo: Repository, session_id: []const u8) !Outcome {
        return capture(self.arena, self.request(repo, session_id, .{}));
    }

    /// The ref a capture of `repo` for `session_id` extends.
    fn sessionRef(self: TestRepos, repo: Repository, session_id: []const u8) ![]const u8 {
        return sessionRefName(self.arena, session_id, repo.git_dir);
    }

    fn store(self: TestRepos, repo: Repository) ![]const u8 {
        return storeGitDir(self.arena, try storeDir(self.arena, self.profile, repo.common_dir));
    }

    fn storeGit(self: TestRepos, repo: Repository, args: []const []const u8) ![]const u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(self.arena, &.{ "--git-dir", try self.store(repo) });
        try argv.appendSlice(self.arena, args);
        return self.git(self.root, argv.items);
    }

    /// One file of a stored tree, read from the store.
    fn storedFile(self: TestRepos, repo: Repository, tree: []const u8, file: []const u8) ![]const u8 {
        return self.storeGit(repo, &.{ "cat-file", "blob", try self.arena.print("{s}:{s}", .{ tree, file }) });
    }

    fn treeHas(self: TestRepos, repo: Repository, tree: []const u8, file: []const u8) !bool {
        return (try self.storeGit(repo, &.{ "ls-tree", "--name-only", tree, "--", file })).len != 0;
    }

    /// The object a store ref names, or null when the store or ref is missing.
    fn storeRef(self: TestRepos, repo: Repository, ref: []const u8) !?[]const u8 {
        const store_dir = try self.store(repo);
        if (!try existsAbsolute(store_dir)) return null;
        const result = try self.run(self.root, try self.gitArgv(&.{ "--git-dir", store_dir, "rev-parse", "-q", "--verify", ref }), &.{});
        return switch (result.term) {
            .exited => |code| if (code == 0) std.mem.trimEnd(u8, result.stdout, "\n") else null,
            else => null,
        };
    }

    fn storeRefs(self: TestRepos, repo: Repository) ![]const u8 {
        if (!try existsAbsolute(try self.store(repo))) return "";
        return self.storeGit(repo, &.{ "for-each-ref", "--format=%(refname) %(objectname)" });
    }

    // Oracles.

    /// The tree the user's own git records for the worktree as it is now:
    /// `git add -A` and `write-tree` on a copy of the worktree's index that
    /// keeps its time, minus the paths the capture leaves out on purpose.
    /// New objects go to a scratch object directory, so the oracle writes
    /// nothing into the user's repository or the store.
    fn expectedTree(self: TestRepos, repo: Repository, excluded: []const []const u8) ![]const u8 {
        const index_file = try self.path("oracle.index");
        try deleteIfPresent(index_file);
        const user_index = try std.Io.Dir.path.join(self.arena, &.{ repo.git_dir, "index" });
        if (try existsAbsolute(user_index)) try self.copyKeepingTime(user_index, index_file);
        const objects = try self.path("oracle-objects");
        try std.Io.Dir.cwd().deleteTree(testing.io, objects);
        try std.Io.Dir.cwd().createDirPath(testing.io, objects);
        const env = [_]EnvPair{
            .{ "GIT_INDEX_FILE", index_file },
            .{ "GIT_OBJECT_DIRECTORY", objects },
            .{ "GIT_ALTERNATE_OBJECT_DIRECTORIES", try std.Io.Dir.path.join(self.arena, &.{ repo.common_dir, "objects" }) },
        };
        _ = try self.gitEnv(repo.work_tree, &(oracle_overrides ++ [_][]const u8{ "add", "-A" }), &env);
        for (excluded) |excluded_path| {
            _ = try self.gitEnv(repo.work_tree, &(oracle_overrides ++ [_][]const u8{ "rm", "-q", "--cached", "--ignore-unmatch", "--", excluded_path }), &env);
        }
        return self.gitEnv(repo.work_tree, &(oracle_overrides ++ [_][]const u8{"write-tree"}), &env);
    }

    /// Everything a capture must leave as it found it in the user's
    /// repository, read without refreshing the index.
    fn userState(self: TestRepos, repo: Repository) ![]const u8 {
        const no_locks = [_]EnvPair{.{ "GIT_OPTIONAL_LOCKS", "0" }};
        var out: std.Io.Writer.Allocating = .init(self.arena);
        const w = &out.writer;
        try w.print("status:\n{s}\n", .{try self.gitEnv(repo.work_tree, &(oracle_overrides ++ [_][]const u8{ "status", "--porcelain=v1", "-uall" }), &no_locks)});
        try w.print("index:\n{s}\n", .{try self.gitEnv(repo.work_tree, &(oracle_overrides ++ [_][]const u8{ "ls-files", "-s", "-v" }), &no_locks)});
        try w.print("refs:\n{s}\n", .{try self.gitEnv(repo.work_tree, &.{ "for-each-ref", "--format=%(refname) %(objectname)" }, &no_locks)});
        for ([_][]const u8{ "index", "HEAD" }) |name| {
            const file = try std.Io.Dir.path.join(self.arena, &.{ repo.git_dir, name });
            if (!try existsAbsolute(file)) {
                try w.print("{s}: none\n", .{name});
                continue;
            }
            var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(try readAbsolute(self.arena, file), &digest, .{});
            const stat = try std.Io.Dir.cwd().statFile(testing.io, file, .{});
            try w.print("{s}: {x} {d}\n", .{ name, digest, stat.mtime.nanoseconds });
        }
        const config = try std.Io.Dir.path.join(self.arena, &.{ repo.common_dir, "config" });
        try w.print("config:\n{s}\n", .{try readAbsolute(self.arena, config)});
        return out.written();
    }

    /// Checks `tree` out of the store into an empty folder and compares each
    /// of `paths` with the worktree: bytes, executable bit and symlink target.
    /// Proves the store, alone or through its alternates, holds every object.
    fn expectRestores(self: TestRepos, repo: Repository, tree: []const u8, paths: []const []const u8) !void {
        const out = try self.path("restore");
        try std.Io.Dir.cwd().deleteTree(testing.io, out);
        try std.Io.Dir.cwd().createDirPath(testing.io, out);
        const index_file = try self.path("restore.index");
        try deleteIfPresent(index_file);
        const env = [_]EnvPair{.{ "GIT_INDEX_FILE", index_file }};
        const store_dir = try self.store(repo);
        _ = try self.gitEnv(self.root, &.{ "--git-dir", store_dir, "--work-tree", out, "read-tree", tree }, &env);
        _ = try self.gitEnv(self.root, &.{ "--git-dir", store_dir, "--work-tree", out, "checkout-index", "-a", "-f" }, &env);
        for (paths) |rel| {
            const source = try std.Io.Dir.path.join(self.arena, &.{ repo.work_tree, rel });
            const restored = try std.Io.Dir.path.join(self.arena, &.{ out, rel });
            const source_stat = try std.Io.Dir.cwd().statFile(testing.io, source, .{ .follow_symlinks = false });
            const restored_stat = std.Io.Dir.cwd().statFile(testing.io, restored, .{ .follow_symlinks = false }) catch |err| {
                std.debug.print("restore is missing {s}\n", .{rel});
                return err;
            };
            try testing.expectEqual(source_stat.kind, restored_stat.kind);
            if (source_stat.kind == .sym_link) {
                var source_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                var restored_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const source_len = try std.Io.Dir.cwd().readLink(testing.io, source, &source_buf);
                const restored_len = try std.Io.Dir.cwd().readLink(testing.io, restored, &restored_buf);
                try testing.expectEqualStrings(source_buf[0..source_len], restored_buf[0..restored_len]);
                continue;
            }
            try testing.expectEqualSlices(u8, try readAbsolute(self.arena, source), try readAbsolute(self.arena, restored));
            try testing.expectEqual(source_stat.permissions.toMode() & 0o100, restored_stat.permissions.toMode() & 0o100);
        }
    }

    /// How many times the sentinel program ran since the last call.
    fn sentinelRuns(self: TestRepos) !usize {
        const data = readAbsolute(self.arena, self.sentinel_log) catch |err| switch (err) {
            error.FileNotFound => return 0,
            else => return err,
        };
        try std.Io.Dir.deleteFileAbsolute(testing.io, self.sentinel_log);
        return std.mem.count(u8, data, "ran\n");
    }

    // Repository shapes a capture must store as the user's git would.

    fn in(self: TestRepos, repo_name: []const u8, rel: []const u8) ![]const u8 {
        return std.Io.Dir.path.join(self.arena, &.{ repo_name, rel });
    }

    /// `make_repo`: a committed repository with every shape the capture must
    /// handle.
    fn makeShapes(self: TestRepos, name: []const u8) !void {
        try self.initRepo(name);
        const files = [_]EnvPair{
            .{ "a.txt", "one\n" },
            .{ "dir/b.txt", "b\n" },
            .{ "space name.txt", "space\n" },
            .{ "\xc3\xb1and\xc3\xba.txt", "unicode\n" },
            .{ "nested/.gitignore", "tmp/\n" },
            .{ "nested/c.txt", "c\n" },
            .{ "todelete.txt", "delete me\n" },
            .{ "torename.txt", "rename me\n" },
            .{ ".gitignore", "*.log\n" },
            .{ "keep.log", "tracked but ignored\n" },
            .{ "exec.sh", "#!/bin/sh\necho hi\n" },
        };
        for (files) |file| try self.write(try self.in(name, file[0]), file[1]);
        try self.chmod(try self.in(name, "exec.sh"), 0o755);
        try self.symlink("a.txt", try self.in(name, "link"));
        try self.write(try self.in(name, "bin.dat"), try self.randomBytes(4096, 1));
        _ = try self.gitIn(name, &.{ "add", "-A" });
        _ = try self.gitIn(name, &.{ "add", "-f", "keep.log" });
        try self.commit(name, "base");
    }

    /// `dirty_repo`. `big.bin` is larger than `shapes_limits` allows for an
    /// untracked file.
    fn dirtyShapes(self: TestRepos, name: []const u8) !void {
        try self.append(try self.in(name, "a.txt"), "two\n");
        try self.append(try self.in(name, "dir/b.txt"), "staged\n");
        _ = try self.gitIn(name, &.{ "add", "dir/b.txt" });
        try self.append(try self.in(name, "dir/b.txt"), "unstaged\n");
        try self.chmod(try self.in(name, "exec.sh"), 0o644);
        try self.remove(try self.in(name, "todelete.txt"));
        try self.rename(try self.in(name, "torename.txt"), try self.in(name, "renamed.txt"));
        try self.remove(try self.in(name, "link"));
        try self.symlink("dir/b.txt", try self.in(name, "link"));
        try self.write(try self.in(name, "new.txt"), "new\n");
        try self.write(try self.in(name, "newdir/x.txt"), "x\n");
        try self.write(try self.in(name, "new.bin"), try self.randomBytes(1000, 2));
        try self.write(try self.in(name, "debug.log"), "ignored\n");
        try self.write(try self.in(name, "nested/tmp/t.txt"), "t\n");
        try self.write(try self.in(name, "local.txt"), "local\n");
        try self.append(try self.in(name, ".git/info/exclude"), "local.txt\n");
        try self.write(try self.in(name, ".env"), "SECRET=1\n");
        try self.write(try self.in(name, "big.bin"), try self.randomBytes(100 * 1024, 3));
        try self.append(try self.in(name, "keep.log"), "more tracked-ignored\n");
    }

    /// A main worktree and a linked `side` worktree, each on its own branch
    /// with a different `out/b`, both in a sparse cone that leaves `out/` off
    /// disk.
    fn makeTwoWorktrees(self: TestRepos) !void {
        try self.initRepo("wt-main");
        try self.write("wt-main/in/a", "i\n");
        try self.write("wt-main/out/b", "main\n");
        _ = try self.gitIn("wt-main", &.{ "add", "-A" });
        try self.commit("wt-main", "base");
        _ = try self.gitIn("wt-main", &.{ "worktree", "add", "-q", "-b", "side", try self.path("wt-side") });
        try self.write("wt-side/out/b", "side\n");
        try self.commitAll("wt-side", "side");
        _ = try self.gitIn("wt-side", &.{ "sparse-checkout", "set", "--cone", "in" });
        _ = try self.gitIn("wt-main", &.{ "sparse-checkout", "set", "--cone", "in" });
    }
};

const shapes_limits: policy.Limits = .{ .untracked_file_bytes = 64 * 1024 };
const shapes_excluded = [_][]const u8{ ".env", "big.bin" };
const shapes_restored = [_][]const u8{
    "a.txt",       "dir/b.txt", "exec.sh", "link",         "bin.dat",  "space name.txt", "\xc3\xb1and\xc3\xba.txt",
    "renamed.txt", "new.txt",   "new.bin", "newdir/x.txt", "keep.log", "nested/c.txt",   "nested/.gitignore",
};

fn printOutcome(outcome: Outcome) void {
    std.debug.print("capture outcome: status={s} reason={s} tree={s}\n", .{
        @tagName(outcome.status),
        if (outcome.reason) |reason| @tagName(reason) else "none",
        outcome.tree orelse "none",
    });
}

/// A capture that wrote a tree and a commit; returns the tree.
fn expectStored(outcome: Outcome) ![]const u8 {
    switch (outcome.status) {
        .complete, .partial => {},
        .failed, .unavailable => {
            printOutcome(outcome);
            return error.TestExpectedStoredCapture;
        },
    }
    const tree = outcome.tree orelse return error.TestExpectedTree;
    if (outcome.commit == null) return error.TestExpectedCommit;
    if (outcome.status == .partial and outcome.reason == null) return error.TestExpectedReason;
    return tree;
}

fn expectComplete(outcome: Outcome) ![]const u8 {
    const tree = try expectStored(outcome);
    if (outcome.status != .complete) printOutcome(outcome);
    try testing.expectEqual(Status.complete, outcome.status);
    try testing.expect(outcome.reason == null);
    return tree;
}

/// A capture that wrote nothing and says why.
fn expectNotStored(outcome: Outcome) !void {
    if (outcome.status == .complete or outcome.status == .partial) {
        printOutcome(outcome);
        return error.TestExpectedNoCapture;
    }
    try testing.expect(outcome.reason != null);
    try testing.expect(outcome.tree == null);
    try testing.expect(outcome.commit == null);
}

fn exclusionReason(outcome: Outcome, path: []const u8) ?ExclusionReason {
    for (outcome.excluded) |entry| {
        if (std.mem.eql(u8, entry.path, path)) return entry.reason;
    }
    return null;
}

fn expectExcluded(outcome: Outcome, path: []const u8, reason: ExclusionReason) !void {
    const found = exclusionReason(outcome, path) orelse {
        std.debug.print("{s} is not in the capture's exclusions\n", .{path});
        return error.TestExpectedExclusion;
    };
    try testing.expectEqual(reason, found);
}

const CaptureJob = struct {
    arena_state: std.heap.ArenaAllocator,
    request: Request,
    outcome: ?Outcome = null,

    fn run(job: *CaptureJob) void {
        job.outcome = capture(job.arena_state.allocator(), job.request) catch null;
    }
};

/// Starts every job on its own thread at once and waits for all of them.
fn captureConcurrently(jobs: []CaptureJob) !void {
    var threads: [2]std.Thread = undefined;
    std.debug.assert(jobs.len <= threads.len);
    var started: usize = 0;
    defer for (threads[0..started]) |thread| thread.join();
    for (jobs) |*job| {
        threads[started] = try std.Thread.spawn(.{}, CaptureJob.run, .{job});
        started += 1;
    }
}

test "capture store: dirty worktree matches the user's git, restores byte for byte and leaves the repository untouched" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    try repos.dirtyShapes("repo");
    const repo = try repos.repository("repo");
    const before = try repos.userState(repo);
    const expected = try repos.expectedTree(repo, &shapes_excluded);
    const head = try repos.gitIn("repo", &.{ "rev-parse", "HEAD" });

    const outcome = try capture(repos.arena, repos.request(repo, "one", shapes_limits));
    const tree = try expectStored(outcome);
    try testing.expectEqualStrings(expected, tree);
    try testing.expectEqual(Status.partial, outcome.status);
    try testing.expect(outcome.reason.? == .sensitive or outcome.reason.? == .too_large);
    try testing.expect(!outcome.comparable);
    try expectExcluded(outcome, ".env", .sensitive);
    try expectExcluded(outcome, "big.bin", .too_large);
    for (outcome.excluded) |entry| {
        try testing.expect(std.mem.eql(u8, entry.path, ".env") or std.mem.eql(u8, entry.path, "big.bin"));
    }
    try testing.expectEqualStrings(head, outcome.head.commit);
    try testing.expectEqual(@as(?safe_git.ObjectFormat, .sha1), outcome.object_format);
    try testing.expectEqual(@as(?IndexStart, .copied), outcome.index);
    try testing.expectEqual(@as(?Listing, .indexer), outcome.listing);
    try testing.expectEqualStrings(outcome.commit.?, (try repos.storeRef(repo, try repos.sessionRef(repo, "one"))).?);
    try testing.expectEqualStrings("tree", try repos.storeGit(repo, &.{ "cat-file", "-t", tree }));

    try testing.expect(try repos.treeHas(repo, tree, "keep.log"));
    for ([_][]const u8{ "local.txt", "todelete.txt", "torename.txt", "debug.log", "nested/tmp", ".env", "big.bin" }) |absent| {
        try testing.expect(!try repos.treeHas(repo, tree, absent));
    }
    try testing.expectEqualStrings("100644", (try repos.storeGit(repo, &.{ "ls-tree", tree, "exec.sh" }))[0..6]);
    try testing.expectEqualStrings("120000", (try repos.storeGit(repo, &.{ "ls-tree", tree, "link" }))[0..6]);
    try repos.expectRestores(repo, tree, &shapes_restored);
    try testing.expectEqualStrings(before, try repos.userState(repo));
}

test "capture store: successive captures chain on the session ref and follow the worktree" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    try repos.dirtyShapes("repo");
    const repo = try repos.repository("repo");
    const ref = try repos.sessionRef(repo, "one");
    const ref_parent = try repos.arena.print("{s}^", .{ref});

    const first = try capture(repos.arena, repos.request(repo, "one", shapes_limits));
    _ = try expectStored(first);

    // A previous untracked file goes away and another becomes ignored.
    try repos.remove("repo/new.txt");
    try repos.append("repo/.gitignore", "newdir/\n");
    try repos.write("repo/later.txt", "later\n");
    const expected_second = try repos.expectedTree(repo, &shapes_excluded);
    const second = try capture(repos.arena, repos.request(repo, "one", shapes_limits));
    const second_tree = try expectStored(second);
    try testing.expectEqualStrings(expected_second, second_tree);
    try testing.expectEqual(@as(?IndexStart, .persisted), second.index);
    try testing.expect(!try repos.treeHas(repo, second_tree, "new.txt"));
    try testing.expect(!try repos.treeHas(repo, second_tree, "newdir"));
    try testing.expect(try repos.treeHas(repo, second_tree, "later.txt"));
    try testing.expectEqualStrings("2", try repos.storeGit(repo, &.{ "rev-list", "--count", ref }));
    try testing.expectEqualStrings(second.commit.?, (try repos.storeRef(repo, ref)).?);
    try testing.expectEqualStrings(first.commit.?, try repos.storeGit(repo, &.{ "rev-parse", ref_parent }));

    // The user commits the same state: the capture equals the new commit's tree.
    try repos.remove("repo/.env");
    try repos.remove("repo/big.bin");
    _ = try repos.gitIn("repo", &.{ "add", "-A" });
    try repos.commit("repo", "work");
    const third = try repos.captureRepo(repo, "one");
    try testing.expectEqualStrings(try repos.gitIn("repo", &.{ "rev-parse", "HEAD^{tree}" }), try expectComplete(third));
    try testing.expect(third.comparable);
    try testing.expectEqualStrings(try repos.gitIn("repo", &.{ "rev-parse", "HEAD" }), third.head.commit);
    try testing.expectEqualStrings("3", try repos.storeGit(repo, &.{ "rev-list", "--count", ref }));
    try testing.expectEqualStrings(second.commit.?, try repos.storeGit(repo, &.{ "rev-parse", ref_parent }));
    // Capture ref updates keep no reflog that would hold old captures.
    try testing.expect(!try TestRepos.existsAbsolute(try std.Io.Dir.path.join(repos.arena, &.{ try repos.store(repo), "logs", "refs", "fx" })));
}

test "capture store: captures on the session ref survive gc --prune=now in the store" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    try repos.dirtyShapes("repo");
    const repo = try repos.repository("repo");

    const first_tree = try expectStored(try capture(repos.arena, repos.request(repo, "one", shapes_limits)));
    const first_blob = try repos.storeGit(repo, &.{ "rev-parse", try repos.arena.print("{s}:new.txt", .{first_tree}) });
    try repos.write("repo/new.txt", "changed after the first capture\n");
    const second_tree = try expectStored(try capture(repos.arena, repos.request(repo, "one", shapes_limits)));

    _ = try repos.storeGit(repo, &.{ "gc", "-q", "--prune=now" });
    try testing.expectEqualStrings("tree", try repos.storeGit(repo, &.{ "cat-file", "-t", first_tree }));
    try testing.expectEqualStrings("blob", try repos.storeGit(repo, &.{ "cat-file", "-t", first_blob }));
    try testing.expectEqualStrings("tree", try repos.storeGit(repo, &.{ "cat-file", "-t", second_tree }));
    try repos.expectRestores(repo, second_tree, &shapes_restored);
}

test "capture store: repository without commits captures its files with no head" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.initRepo("unborn");
    try repos.write("unborn/u.txt", "u\n");
    try repos.write("unborn/d/v.txt", "v\n");
    const repo = try repos.repository("unborn");
    const expected = try repos.expectedTree(repo, &.{});

    const outcome = try repos.captureRepo(repo, "u");
    try testing.expectEqualStrings(expected, try expectComplete(outcome));
    try testing.expect(outcome.head == .unborn);
    try repos.expectRestores(repo, outcome.tree.?, &.{ "u.txt", "d/v.txt" });
}

test "capture store: linked worktree has its own capture index and shares the repository's store" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    _ = try repos.gitIn("repo", &.{ "worktree", "add", "-q", try repos.path("linked"), "-b", "side" });
    try repos.append("linked/a.txt", "wt change\n");
    try repos.write("linked/wt.txt", "wt new\n");
    try repos.write("repo/main-only.txt", "main\n");
    const main = try repos.repository("repo");
    const linked = try repos.repository("linked");
    try testing.expectEqualStrings(main.common_dir, linked.common_dir);
    try testing.expect(!std.mem.eql(u8, main.git_dir, linked.git_dir));
    const expected_linked = try repos.expectedTree(linked, &.{});
    const expected_main = try repos.expectedTree(main, &.{});

    const linked_outcome = try repos.captureRepo(linked, "w");
    try testing.expectEqualStrings(expected_linked, try expectComplete(linked_outcome));
    try testing.expectEqualStrings(try repos.gitIn("linked", &.{ "rev-parse", "HEAD" }), linked_outcome.head.commit);
    const main_outcome = try repos.captureRepo(main, "m");
    try testing.expectEqualStrings(expected_main, try expectComplete(main_outcome));
    try testing.expect(!try repos.treeHas(main, main_outcome.tree.?, "wt.txt"));
    try testing.expect(!try repos.treeHas(linked, linked_outcome.tree.?, "main-only.txt"));

    const store_dir = try repos.store(linked);
    try testing.expectEqualStrings(store_dir, try repos.store(main));
    const alternates = try TestRepos.readAbsolute(repos.arena, try std.Io.Dir.path.join(repos.arena, &.{ store_dir, "objects", "info", "alternates" }));
    try testing.expectEqualStrings(try std.Io.Dir.path.join(repos.arena, &.{ linked.common_dir, "objects" }), std.mem.trimEnd(u8, alternates, "\n"));
    const repo_dir = try storeDir(repos.arena, repos.profile, linked.common_dir);
    const linked_dir = try worktreeDir(repos.arena, repo_dir, linked.git_dir);
    const main_dir = try worktreeDir(repos.arena, repo_dir, main.git_dir);
    try testing.expect(!std.mem.eql(u8, linked_dir, main_dir));
    try testing.expect(try TestRepos.existsAbsolute(linked_dir));
    try testing.expect(try TestRepos.existsAbsolute(main_dir));
}

test "capture store: submodule is recorded as a gitlink at its new HEAD and reported partial" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.initRepo("subsrc");
    try repos.write("subsrc/s.txt", "s1\n");
    _ = try repos.gitIn("subsrc", &.{ "add", "-A" });
    try repos.commit("subsrc", "s1");
    try repos.initRepo("withsub");
    try repos.write("withsub/m.txt", "m\n");
    _ = try repos.gitIn("withsub", &.{ "-c", "protocol.file.allow=always", "submodule", "-q", "add", try repos.path("subsrc"), "sub" });
    try repos.commit("withsub", "with sub");
    try repos.append("withsub/sub/s.txt", "s2\n");
    try repos.commitAll("withsub/sub", "s2");
    try repos.append("withsub/sub/s.txt", "dirty inside\n");
    const sub_head = try repos.gitIn("withsub/sub", &.{ "rev-parse", "HEAD" });
    const repo = try repos.repository("withsub");
    const expected = try repos.expectedTree(repo, &.{});

    const outcome = try repos.captureRepo(repo, "m");
    const tree = try expectStored(outcome);
    try testing.expectEqualStrings(expected, tree);
    try testing.expectEqualStrings(try repos.arena.print("160000 commit {s}\tsub", .{sub_head}), try repos.storeGit(repo, &.{ "ls-tree", tree, "sub" }));
    // The submodule's own dirty content is not captured, so the capture is
    // partial: workspace_capture excludes a present gitlink as `submodule`.
    try testing.expectEqual(Status.partial, outcome.status);
    try testing.expectEqual(policy.Reason.submodule, outcome.reason.?);
    try expectExcluded(outcome, "sub", .submodule);
    try testing.expect(!outcome.comparable);
}

test "capture store: concurrent captures of one worktree both finish in turn and never corrupt the store" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("conc");
    try repos.dirtyShapes("conc");
    const repo = try repos.repository("conc");
    _ = try expectStored(try capture(repos.arena, repos.request(repo, "c1", shapes_limits)));
    try repos.append("conc/a.txt", "race\n");
    const expected = try repos.expectedTree(repo, &shapes_excluded);

    var jobs = [_]CaptureJob{
        .{ .arena_state = .init(testing.allocator), .request = repos.request(repo, "c1", shapes_limits) },
        .{ .arena_state = .init(testing.allocator), .request = repos.request(repo, "c2", shapes_limits) },
    };
    defer for (&jobs) |*job| job.arena_state.deinit();
    try captureConcurrently(&jobs);

    var stored: usize = 0;
    for (jobs) |job| {
        const outcome = job.outcome orelse return error.TestCaptureReturnedError;
        switch (outcome.status) {
            .complete, .partial => {
                stored += 1;
                try testing.expectEqualStrings(expected, try expectStored(outcome));
                const ref = try repos.sessionRef(repo, job.request.session_id);
                try testing.expectEqualStrings(outcome.commit.?, (try repos.storeRef(repo, ref)).?);
            },
            // The second capture waits for the first one's lock.
            .unavailable, .failed => {
                printOutcome(outcome);
                return error.TestUnexpectedFailedCapture;
            },
        }
    }
    try testing.expectEqual(@as(usize, 2), stored);
    const fsck = try repos.run(repos.root, try repos.gitArgv(&.{ "--git-dir", try repos.store(repo), "fsck", "--no-dangling" }), &.{});
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, fsck.term);
    for ([_][]const u8{ "error", "missing", "broken" }) |word| {
        try testing.expect(std.mem.find(u8, fsck.stdout, word) == null);
        try testing.expect(std.mem.find(u8, fsck.stderr, word) == null);
    }
    // The lock leaves with the captures that held it.
    try testing.expectEqualStrings(expected, try expectStored(try capture(repos.arena, repos.request(repo, "c1", shapes_limits))));
}

test "capture store: repository core.autocrlf is applied, so the tree matches the user's and stays comparable" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.initRepo("eol");
    try repos.write("eol/base.txt", "base\n");
    _ = try repos.gitIn("eol", &.{ "add", "-A" });
    try repos.commit("eol", "base");
    _ = try repos.gitIn("eol", &.{ "config", "core.autocrlf", "input" });
    try repos.write("eol/base.txt", "base\r\nmore\r\n");
    try repos.write("eol/crlf.txt", "a\r\nb\r\n");
    const repo = try repos.repository("eol");
    const expected = try repos.expectedTree(repo, &.{});

    const outcome = try repos.captureRepo(repo, "e");
    const tree = try expectComplete(outcome);
    try testing.expectEqualStrings(expected, tree);
    try testing.expect(outcome.comparable);
    try testing.expectEqualStrings("a\nb", try repos.storedFile(repo, tree, "crlf.txt"));
    try testing.expectEqualStrings("base\nmore", try repos.storedFile(repo, tree, "base.txt"));
}

test "capture store: repository filters, fsmonitor and hooks never run during a capture" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("trap");
    try repos.dirtyShapes("trap");
    try TestRepos.writeAbsolute(repos.sentinel, try repos.arena.print("#!/bin/sh\necho ran >> '{s}'\ncat\n", .{repos.sentinel_log}));
    try std.Io.Dir.cwd().setFilePermissions(testing.io, repos.sentinel, .fromMode(0o755), .{});
    try repos.write("trap/.gitattributes", "*.txt filter=evil\n");
    _ = try repos.gitIn("trap", &.{ "config", "filter.evil.clean", repos.sentinel });
    _ = try repos.gitIn("trap", &.{ "config", "filter.evil.process", repos.sentinel });
    _ = try repos.gitIn("trap", &.{ "config", "core.fsmonitor", repos.sentinel });
    try std.Io.Dir.cwd().createDirPath(testing.io, try repos.path("trap/.git/hooks"));
    for ([_][]const u8{ "post-index-change", "reference-transaction", "pre-commit", "post-checkout" }) |hook| {
        try repos.symlink(repos.sentinel, try repos.arena.print("trap/.git/hooks/{s}", .{hook}));
    }
    const repo = try repos.repository("trap");
    _ = try repos.sentinelRuns();

    _ = try expectStored(try capture(repos.arena, repos.request(repo, "x", shapes_limits)));
    try testing.expectEqual(@as(usize, 0), try repos.sentinelRuns());

    // Control: the user's plain git in the same repository runs them.
    _ = try repos.run(repo.work_tree, try repos.gitArgv(&.{ "add", "-A" }), &.{});
    _ = try repos.run(repo.work_tree, try repos.gitArgv(&.{ "reset", "-q" }), &.{});
    try testing.expect(try repos.sentinelRuns() > 0);
}

test "capture store: sparse checkout keeps tracked files that are off disk on purpose" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.initRepo("sparse");
    try repos.write("sparse/in/a", "i\n");
    try repos.write("sparse/out/b", "o\n");
    _ = try repos.gitIn("sparse", &.{ "add", "-A" });
    try repos.commit("sparse", "base");
    _ = try repos.gitIn("sparse", &.{ "sparse-checkout", "set", "--cone", "in" });
    try testing.expect(!try repos.exists("sparse/out/b"));
    const repo = try repos.repository("sparse");
    const before = try repos.userState(repo);

    const clean = try repos.captureRepo(repo, "sp");
    try testing.expectEqualStrings(try repos.gitIn("sparse", &.{ "rev-parse", "HEAD^{tree}" }), try expectComplete(clean));
    try testing.expectEqualStrings(before, try repos.userState(repo));

    try repos.append("sparse/in/a", "edited\n");
    const expected = try repos.expectedTree(repo, &.{});
    const tree = try expectComplete(try repos.captureRepo(repo, "sp"));
    try testing.expectEqualStrings(expected, tree);
    try testing.expectEqualStrings("o", try repos.storedFile(repo, tree, "out/b"));
}

test "capture store: split index rebuilds the capture index from HEAD and lists with git" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.initRepo("split");
    _ = try repos.gitIn("split", &.{ "config", "core.splitIndex", "true" });
    try repos.write("split/x", "x\n");
    try repos.write("split/d/y", "y\n");
    _ = try repos.gitIn("split", &.{ "add", "-A" });
    try repos.commit("split", "base");
    try repos.append("split/x", "more\n");
    try repos.write("split/n.txt", "new\n");
    // Fixture check: the index really is split.
    var git_dir = try std.Io.Dir.cwd().openDir(testing.io, try repos.path("split/.git"), .{ .iterate = true });
    defer git_dir.close(testing.io);
    var entries = git_dir.iterate();
    var shared = false;
    while (try entries.next(testing.io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, "sharedindex.")) shared = true;
    }
    try testing.expect(shared);
    const repo = try repos.repository("split");
    const expected = try repos.expectedTree(repo, &.{});

    const outcome = try repos.captureRepo(repo, "si");
    try testing.expectEqualStrings(expected, try expectComplete(outcome));
    try testing.expectEqual(@as(?IndexStart, .rebuilt), outcome.index);
    try testing.expectEqual(@as(?Listing, .git), outcome.listing);
}

test "capture store: sparse index is unavailable with index_sparse and writes no tree" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.initRepo("sparseidx");
    try repos.write("sparseidx/in/a", "i\n");
    try repos.write("sparseidx/out/b", "o\n");
    _ = try repos.gitIn("sparseidx", &.{ "add", "-A" });
    try repos.commit("sparseidx", "base");
    _ = try repos.gitIn("sparseidx", &.{ "sparse-checkout", "set", "--cone", "--sparse-index", "in" });
    const repo = try repos.repository("sparseidx");
    const before = try repos.userState(repo);

    const outcome = try repos.captureRepo(repo, "sx");
    try expectNotStored(outcome);
    try testing.expectEqual(Status.unavailable, outcome.status);
    try testing.expectEqual(policy.Reason.index_sparse, outcome.reason.?);
    try testing.expect(try repos.storeRef(repo, try repos.sessionRef(repo, "sx")) == null);
    try testing.expectEqualStrings(before, try repos.userState(repo));
}

test "capture store: assume-unchanged and present skip-worktree files are captured from disk and the user's bits stay" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.initRepo("flags");
    for ([_][]const u8{ "flags/au.txt", "flags/sw.txt", "flags/plain.txt" }) |file| try repos.write(file, "one\n");
    _ = try repos.gitIn("flags", &.{ "add", "-A" });
    try repos.commit("flags", "base");
    _ = try repos.gitIn("flags", &.{ "update-index", "--assume-unchanged", "au.txt" });
    _ = try repos.gitIn("flags", &.{ "update-index", "--skip-worktree", "sw.txt" });
    try repos.write("flags/au.txt", "two\n");
    try repos.write("flags/sw.txt", "two\n");
    const repo = try repos.repository("flags");
    const before = try repos.userState(repo);

    const tree = try expectComplete(try repos.captureRepo(repo, "fl"));
    try testing.expectEqualStrings("two", try repos.storedFile(repo, tree, "au.txt"));
    try testing.expectEqualStrings("two", try repos.storedFile(repo, tree, "sw.txt"));
    try testing.expectEqualStrings("one", try repos.storedFile(repo, tree, "plain.txt"));
    try repos.expectRestores(repo, tree, &.{ "au.txt", "sw.txt", "plain.txt" });
    try testing.expectEqualStrings("h au.txt\nS sw.txt", try repos.gitIn("flags", &.{ "ls-files", "-v", "au.txt", "sw.txt" }));
    try testing.expectEqualStrings(before, try repos.userState(repo));
}

test "capture store: sparse checkout that changes between captures takes HEAD's version off disk and the disk's on disk" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.initRepo("sl");
    try repos.write("sl/in/a", "i\n");
    try repos.write("sl/out/b", "old\n");
    _ = try repos.gitIn("sl", &.{ "add", "-A" });
    try repos.commit("sl", "base");
    _ = try repos.gitIn("sl", &.{ "sparse-checkout", "set", "--cone", "in" });
    const repo = try repos.repository("sl");
    _ = try expectComplete(try repos.captureRepo(repo, "sl"));

    _ = try repos.gitIn("sl", &.{ "sparse-checkout", "disable" });
    try repos.write("sl/out/b", "new\n");
    try repos.commitAll("sl", "update");
    _ = try repos.gitIn("sl", &.{ "sparse-checkout", "set", "--cone", "in" });
    try testing.expect(!try repos.exists("sl/out/b"));
    const moved = try expectComplete(try repos.captureRepo(repo, "sl"));
    try testing.expectEqualStrings(try repos.gitIn("sl", &.{ "rev-parse", "HEAD^{tree}" }), moved);
    try testing.expectEqualStrings("new", try repos.storedFile(repo, moved, "out/b"));

    _ = try repos.gitIn("sl", &.{ "sparse-checkout", "disable" });
    try repos.write("sl/out/b", "edited\n");
    const expected = try repos.expectedTree(repo, &.{});
    const back = try expectComplete(try repos.captureRepo(repo, "sl"));
    try testing.expectEqualStrings(expected, back);
    try testing.expectEqualStrings("edited", try repos.storedFile(repo, back, "out/b"));
}

test "capture store: two worktrees of one repository each capture their own branch" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeTwoWorktrees();
    const main = try repos.repository("wt-main");
    const side = try repos.repository("wt-side");
    const main_head_tree = try repos.gitIn("wt-main", &.{ "rev-parse", "HEAD^{tree}" });
    const side_head_tree = try repos.gitIn("wt-side", &.{ "rev-parse", "HEAD^{tree}" });
    try testing.expect(!std.mem.eql(u8, main_head_tree, side_head_tree));

    try testing.expectEqualStrings(main_head_tree, try expectComplete(try repos.captureRepo(main, "wm")));
    try testing.expectEqualStrings(side_head_tree, try expectComplete(try repos.captureRepo(side, "ws")));
    try testing.expectEqualStrings(main_head_tree, try expectComplete(try repos.captureRepo(main, "wm")));
}

test "capture store: with core.checkStat=minimal two worktrees with equal size and time capture their own file" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.append("home/.gitconfig", "[core]\n\tcheckStat = minimal\n");
    try repos.initRepo("cs-main");
    try repos.write("cs-main/f", "main\n");
    _ = try repos.gitIn("cs-main", &.{ "add", "-A" });
    try repos.commit("cs-main", "base");
    _ = try repos.gitIn("cs-main", &.{ "worktree", "add", "-q", "-b", "side", try repos.path("cs-side") });
    try repos.write("cs-side/f", "side\n");
    try repos.commitAll("cs-side", "side");
    // Same size, same time, different content.
    try repos.setModified("cs-main/f", 1_577_836_800);
    try repos.setModified("cs-side/f", 1_577_836_800);
    const main = try repos.repository("cs-main");
    const side = try repos.repository("cs-side");

    const main_tree = try expectComplete(try repos.captureRepo(main, "cm"));
    const side_tree = try expectComplete(try repos.captureRepo(side, "cs"));
    try testing.expectEqualStrings("main", try repos.storedFile(main, main_tree, "f"));
    try testing.expectEqualStrings("side", try repos.storedFile(side, side_tree, "f"));
}

test "capture store: branch switch between captures is followed by the persistent capture index" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.initRepo("switch");
    try repos.write("switch/f", "a\n");
    try repos.write("switch/k", "keep\n");
    _ = try repos.gitIn("switch", &.{ "add", "-A" });
    try repos.commit("switch", "base");
    _ = try repos.gitIn("switch", &.{ "checkout", "-q", "-b", "other" });
    try repos.write("switch/f", "b\n");
    try repos.write("switch/g", "extra\n");
    _ = try repos.gitIn("switch", &.{ "add", "-A" });
    try repos.commit("switch", "other");
    _ = try repos.gitIn("switch", &.{ "checkout", "-q", "main" });
    try repos.append("switch/k", "dirty\n");
    const repo = try repos.repository("switch");
    const expected_first = try repos.expectedTree(repo, &.{});
    try testing.expectEqualStrings(expected_first, try expectComplete(try repos.captureRepo(repo, "bs")));

    _ = try repos.gitIn("switch", &.{ "checkout", "-q", "--", "k" });
    _ = try repos.gitIn("switch", &.{ "checkout", "-q", "other" });
    try repos.write("switch/h.txt", "wip\n");
    const expected = try repos.expectedTree(repo, &.{});
    const second = try repos.captureRepo(repo, "bs");
    try testing.expectEqualStrings(expected, try expectComplete(second));
    try testing.expectEqual(@as(?IndexStart, .persisted), second.index);
    try testing.expectEqualStrings(try repos.gitIn("switch", &.{ "rev-parse", "HEAD" }), second.head.commit);
}

test "capture store: same-size change in the index's own second is captured because the index copy keeps its time" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.initRepo("racy");
    // Start right after a second boundary, so the index write and the edit
    // share one second, then capture in a later second.
    const now_ns = std.Io.Timestamp.now(testing.io, .real).nanoseconds;
    const into_second: u64 = @intCast(@mod(now_ns, std.time.ns_per_s));
    io_mod.sleep(std.time.ns_per_s - into_second + 20 * std.time.ns_per_ms);
    try repos.write("racy/f", "one\n");
    _ = try repos.gitIn("racy", &.{ "add", "f" });
    try repos.commit("racy", "base");
    try repos.write("racy/f", "two\n");
    io_mod.sleep(1200 * std.time.ns_per_ms);
    const repo = try repos.repository("racy");
    // Fixture check: the user's own git sees the change without refreshing.
    try testing.expectEqualStrings(" M f", try repos.gitEnv(repo.work_tree, &.{ "status", "--porcelain" }, &.{.{ "GIT_OPTIONAL_LOCKS", "0" }}));

    const tree = try expectComplete(try repos.captureRepo(repo, "rc"));
    try testing.expectEqualStrings("two", try repos.storedFile(repo, tree, "f"));
    try repos.expectRestores(repo, tree, &.{"f"});
}

test "capture store: captures of two worktrees running at the same time each record their own worktree" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeTwoWorktrees();
    const main = try repos.repository("wt-main");
    const side = try repos.repository("wt-side");
    // The store and both capture indexes exist before the race: this test is
    // about per-worktree intermediates, not store creation. The API has no
    // hook to pause a capture, so unlike run.sh's barrier the interleaving is
    // left to the scheduler over several rounds.
    _ = try expectComplete(try repos.captureRepo(main, "wm"));
    _ = try expectComplete(try repos.captureRepo(side, "ws"));

    var round: usize = 0;
    while (round < 4) : (round += 1) {
        try repos.write(try repos.arena.print("wt-main/in/main-{d}.txt", .{round}), "main\n");
        try repos.write(try repos.arena.print("wt-side/in/side-{d}.txt", .{round}), "side side\n");
        try repos.append("wt-main/in/a", "main edit\n");
        try repos.append("wt-side/in/a", "side edit\n");
        const expected_main = try repos.expectedTree(main, &.{});
        const expected_side = try repos.expectedTree(side, &.{});
        var jobs = [_]CaptureJob{
            .{ .arena_state = .init(testing.allocator), .request = repos.request(main, "wm", .{}) },
            .{ .arena_state = .init(testing.allocator), .request = repos.request(side, "ws", .{}) },
        };
        defer for (&jobs) |*job| job.arena_state.deinit();
        try captureConcurrently(&jobs);
        try testing.expectEqualStrings(expected_main, try expectComplete(jobs[0].outcome orelse return error.TestCaptureReturnedError));
        try testing.expectEqualStrings(expected_side, try expectComplete(jobs[1].outcome orelse return error.TestCaptureReturnedError));
    }
}

test "capture store: untracked limits and sensitive names make a partial capture that lists what it left out" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.initRepo("limits");
    try repos.write("limits/tracked.txt", "tracked\n");
    try repos.write("limits/tracked-big.bin", try repos.randomBytes(8 * 1024, 4));
    _ = try repos.gitIn("limits", &.{ "add", "-A" });
    try repos.commit("limits", "base");
    try repos.write("limits/.env", "SECRET=1\n");
    try repos.write("limits/big.dat", try repos.randomBytes(4 * 1024, 5));
    try repos.write("limits/keep1.txt", "admitted\n");
    try repos.write("limits/keep2.txt", "over the count\n");
    try repos.append("limits/tracked-big.bin", "grows past the untracked limit\n");
    const repo = try repos.repository("limits");
    const expected = try repos.expectedTree(repo, &.{ ".env", "big.dat", "keep2.txt" });

    const limits: policy.Limits = .{ .untracked_file_bytes = 1024, .untracked_count = 1 };
    const outcome = try capture(repos.arena, repos.request(repo, "lim", limits));
    const tree = try expectStored(outcome);
    try testing.expectEqualStrings(expected, tree);
    try testing.expectEqual(Status.partial, outcome.status);
    const reason = outcome.reason.?;
    try testing.expect(reason == .sensitive or reason == .too_large or reason == .file_limit);
    try testing.expect(!outcome.comparable);
    try expectExcluded(outcome, ".env", .sensitive);
    try expectExcluded(outcome, "big.dat", .too_large);
    try expectExcluded(outcome, "keep2.txt", .file_limit);
    // Tracked files never get untracked limits.
    try testing.expect(exclusionReason(outcome, "tracked-big.bin") == null);
    try testing.expect(try repos.treeHas(repo, tree, "tracked-big.bin"));
    try testing.expect(try repos.treeHas(repo, tree, "keep1.txt"));
}

test "capture store: invalid session id writes nothing and is reported as an outcome" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    try repos.write("repo/new.txt", "new\n");
    const repo = try repos.repository("repo");
    const before = try repos.userState(repo);
    const too_long = try repos.arena.alloc(u8, 256);
    @memset(too_long, 'a');

    for ([_][]const u8{ "", "../escape", "a/b", "a b", ".hidden", "refs/heads/main", "x\n", too_long }) |session_id| {
        const outcome = try repos.captureRepo(repo, session_id);
        try expectNotStored(outcome);
        try testing.expectEqual(Status.failed, outcome.status);
        try testing.expectEqual(policy.Reason.invalid_request, outcome.reason.?);
    }
    // Rejected before touching the profile: no store, no worktree directory.
    try testing.expect(!try TestRepos.existsAbsolute(try std.Io.Dir.path.join(repos.arena, &.{ repos.profile, "captures" })));
    try testing.expectEqualStrings("", try repos.storeRefs(repo));
    try testing.expectEqualStrings(before, try repos.userState(repo));
    // Control: the same repository with a valid id captures, and that ref is
    // the only one in the store.
    const valid = try repos.captureRepo(repo, "Valid_id-1");
    _ = try expectComplete(valid);
    try testing.expectEqualStrings(try repos.arena.print("{s} {s}", .{ try repos.sessionRef(repo, "Valid_id-1"), valid.commit.? }), try repos.storeRefs(repo));
}

test "capture store: an expired deadline reports timeout and leaves the session ref alone" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    const repo = try repos.repository("repo");
    const first = try repos.captureRepo(repo, "d");
    _ = try expectComplete(first);
    try repos.append("repo/a.txt", "after\n");
    const before = try repos.userState(repo);

    for ([_][]const u8{ "d", "fresh" }) |session_id| {
        var expired = repos.request(repo, session_id, .{});
        expired.deadline = .fromNow(testing.io, .{ .clock = .awake, .raw = .fromMilliseconds(-1) });
        const outcome = try capture(repos.arena, expired);
        try expectNotStored(outcome);
        try testing.expectEqual(policy.Reason.timeout, outcome.reason.?);
    }
    try testing.expectEqualStrings(first.commit.?, (try repos.storeRef(repo, try repos.sessionRef(repo, "d"))).?);
    try testing.expect(try repos.storeRef(repo, try repos.sessionRef(repo, "fresh")) == null);
    try testing.expectEqualStrings(before, try repos.userState(repo));
}

test "capture store: an untracked nested repository is reported as left out, never dropped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    try repos.initRepo("repo/vendor/lib");
    try repos.write("repo/vendor/lib/x.txt", "x\n");
    _ = try repos.gitIn("repo/vendor/lib", &.{ "add", "-A" });
    try repos.commit("repo/vendor/lib", "lib");
    const repo = try repos.repository("repo");
    const outcome = try repos.captureRepo(repo, "nested");
    const tree = try expectStored(outcome);
    try testing.expectEqual(Status.partial, outcome.status);
    try testing.expectEqual(policy.Reason.submodule, outcome.reason.?);
    try expectExcluded(outcome, "vendor/lib", .submodule);
    try testing.expect(!try repos.treeHas(repo, tree, "vendor/lib"));
    try testing.expect(!outcome.comparable);
    try testing.expectEqual(@as(?Listing, .indexer), outcome.listing);
}

test "capture store: a nested repository found by git's listing is left out, not a failed capture" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    // A split index sends the untracked listing to git, which names a nested
    // repository as `vendor/lib/`.
    _ = try repos.gitIn("repo", &.{ "config", "core.splitIndex", "true" });
    _ = try repos.gitIn("repo", &.{ "update-index", "--split-index" });
    try repos.initRepo("repo/vendor/lib");
    try repos.write("repo/vendor/lib/x.txt", "x\n");
    _ = try repos.gitIn("repo/vendor/lib", &.{ "add", "-A" });
    try repos.commit("repo/vendor/lib", "lib");
    const repo = try repos.repository("repo");
    const outcome = try repos.captureRepo(repo, "nested");
    _ = try expectStored(outcome);
    try testing.expectEqual(@as(?Listing, .git), outcome.listing);
    try expectExcluded(outcome, "vendor/lib", .submodule);
}

test "capture store: one session capturing two worktrees of a repository keeps one ref per worktree" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeTwoWorktrees();
    const main_repo = try repos.repository("wt-main");
    const side_repo = try repos.repository("wt-side");
    const main_outcome = try repos.captureRepo(main_repo, "same");
    const side_outcome = try repos.captureRepo(side_repo, "same");
    _ = try expectStored(main_outcome);
    _ = try expectStored(side_outcome);
    try testing.expectEqualStrings(main_outcome.commit.?, (try repos.storeRef(main_repo, try repos.sessionRef(main_repo, "same"))).?);
    try testing.expectEqualStrings(side_outcome.commit.?, (try repos.storeRef(side_repo, try repos.sessionRef(side_repo, "same"))).?);
    // Each chain starts on its own: neither capture is the other's parent.
    try testing.expectEqualStrings("1", try repos.storeGit(main_repo, &.{ "rev-list", "--count", try repos.sessionRef(main_repo, "same") }));
    try testing.expectEqualStrings("1", try repos.storeGit(side_repo, &.{ "rev-list", "--count", try repos.sessionRef(side_repo, "same") }));
}

test "capture store: a fresh capture index lock is reported, and one older than any capture is removed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    const repo = try repos.repository("repo");
    const first = try repos.captureRepo(repo, "l");
    _ = try expectStored(first);
    const worktree_dir = try worktreeDir(repos.arena, try storeDir(repos.arena, repos.profile, repo.common_dir), repo.git_dir);
    const stale_lock = try std.Io.Dir.path.join(repos.arena, &.{ worktree_dir, "index.lock" });
    try TestRepos.writeAbsolute(stale_lock, "");
    try repos.append("repo/a.txt", "more\n");
    const second = try repos.captureRepo(repo, "l");
    try expectNotStored(second);
    try testing.expectEqual(Status.unavailable, second.status);
    try testing.expectEqual(policy.Reason.capture_locked, second.reason.?);
    try testing.expect(try TestRepos.existsAbsolute(stale_lock));
    try testing.expectEqualStrings(first.commit.?, (try repos.storeRef(repo, try repos.sessionRef(repo, "l"))).?);

    // The same lock, last written longer ago than any capture can run, is
    // a git that died: it is removed under the worktree lock.
    const now = std.Io.Timestamp.now(testing.io, .real);
    const old: std.Io.Timestamp = .{ .nanoseconds = now.nanoseconds - (stale_index_lock_ms + 60_000) * std.time.ns_per_ms };
    try std.Io.Dir.cwd().setTimestamps(testing.io, stale_lock, .{ .access_timestamp = .{ .new = old }, .modify_timestamp = .{ .new = old } });
    const third = try repos.captureRepo(repo, "l");
    _ = try expectComplete(third);
    try testing.expect(!try TestRepos.existsAbsolute(stale_lock));
    try testing.expectEqualStrings("one\nmore", try repos.storedFile(repo, third.tree.?, "a.txt"));
    try testing.expectEqualStrings(third.commit.?, (try repos.storeRef(repo, try repos.sessionRef(repo, "l"))).?);
}

test "capture store: a worktree lock held past the deadline reports capture_locked" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    const repo = try repos.repository("repo");
    const first = try repos.captureRepo(repo, "h");
    _ = try expectStored(first);
    const worktree_dir = try worktreeDir(repos.arena, try storeDir(repos.arena, repos.profile, repo.common_dir), repo.git_dir);
    const held = try std.Io.Dir.createFileAbsolute(testing.io, try std.Io.Dir.path.join(repos.arena, &.{ worktree_dir, "lock" }), .{ .truncate = false, .read = true });
    defer held.close(testing.io);
    try testing.expect(try held.tryLock(testing.io, .exclusive));
    try repos.append("repo/a.txt", "more\n");
    var request = repos.request(repo, "h", .{});
    request.deadline = .fromNow(testing.io, .{ .clock = .awake, .raw = .fromMilliseconds(300) });
    const second = try capture(repos.arena, request);
    try testing.expectEqual(policy.Reason.capture_locked, second.reason.?);
    try testing.expectEqualStrings(first.commit.?, (try repos.storeRef(repo, try repos.sessionRef(repo, "h"))).?);
}

test "capture store: a store missing its alternates is repaired and half-built stores are removed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    const repo = try repos.repository("repo");
    const store_dir = try storeDir(repos.arena, repos.profile, repo.common_dir);
    // A crash during an earlier creation left a half-built store behind.
    const leftover = try std.Io.Dir.path.join(repos.arena, &.{ store_dir, "store.git.tmp-1" });
    try TestRepos.writeAbsolute(try std.Io.Dir.path.join(repos.arena, &.{ leftover, "HEAD" }), "ref: refs/heads/main\n");
    _ = try expectStored(try repos.captureRepo(repo, "r"));
    try testing.expect(!try TestRepos.existsAbsolute(leftover));

    // A store without alternates cannot read the user's objects; the next
    // capture restores them instead of failing forever.
    const alternates = try std.Io.Dir.path.join(repos.arena, &.{ try repos.store(repo), "objects", "info", "alternates" });
    try std.Io.Dir.deleteFileAbsolute(testing.io, alternates);
    try repos.append("repo/a.txt", "more\n");
    const expected = try repos.expectedTree(repo, &.{});
    try testing.expectEqualStrings(expected, try expectComplete(try repos.captureRepo(repo, "r")));
    try testing.expect(try TestRepos.existsAbsolute(alternates));
}

test "capture store: repository-local filters or attributes make a capture not comparable" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    const repo = try repos.repository("repo");
    const plain = try repos.captureRepo(repo, "c");
    _ = try expectComplete(plain);
    try testing.expect(plain.comparable);

    _ = try repos.gitIn("repo", &.{ "config", "filter.local.clean", "cat" });
    const filtered = try repos.captureRepo(repo, "c");
    _ = try expectComplete(filtered);
    try testing.expect(!filtered.comparable);
    _ = try repos.gitIn("repo", &.{ "config", "--unset", "filter.local.clean" });

    try repos.write("repo/.git/info/attributes", "*.txt -text\n");
    const attributed = try repos.captureRepo(repo, "c");
    _ = try expectComplete(attributed);
    try testing.expect(!attributed.comparable);
}

test "capture store: a folder that cannot be read fails the capture instead of dropping its files" {
    if (std.c.getuid() == 0) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    const repo = try repos.repository("repo");
    try repos.chmod("repo/dir", 0o000);
    defer repos.chmod("repo/dir", 0o755) catch {};
    const outcome = try repos.captureRepo(repo, "u");
    try expectNotStored(outcome);
    try testing.expectEqual(Status.failed, outcome.status);
    try testing.expectEqual(policy.Reason.io_error, outcome.reason.?);
}

test "capture store: files under a folder replaced by a symlink are captured as git sees them" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    const repo = try repos.repository("repo");
    try repos.rename("repo/dir", "repo/realdir");
    try repos.symlink("realdir", "repo/dir");
    const expected = try repos.expectedTree(repo, &.{});
    const tree = try expectComplete(try repos.captureRepo(repo, "s"));
    try testing.expectEqualStrings(expected, tree);
    try testing.expectEqualStrings("120000", (try repos.storeGit(repo, &.{ "ls-tree", tree, "dir" }))[0..6]);
}

test "capture store: a folder inside the worktree captures the whole worktree and names it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    const repo = try repos.repository("repo");
    const expected = try repos.expectedTree(repo, &.{});
    var inside = repo;
    inside.work_tree = try std.Io.Dir.path.join(repos.arena, &.{ repo.work_tree, "dir" });
    const outcome = try repos.captureRepo(inside, "p");
    try testing.expectEqualStrings(expected, try expectComplete(outcome));
    const named = outcome.repository orelse return error.TestExpectedRepository;
    try testing.expectEqualStrings(try io_mod.realpathAlloc(repos.arena, repo.work_tree), named.work_tree);
    try testing.expectEqualStrings(try io_mod.realpathAlloc(repos.arena, repo.git_dir), named.git_dir);
    try testing.expectEqualStrings(try repos.sessionRef(repo, "p"), outcome.ref.?);
    try testing.expectEqualStrings(outcome.commit.?, (try repos.storeRef(repo, outcome.ref.?)).?);
}

test "capture store: a folder no repository holds is unavailable, not a failed capture" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    // Outside fx's own checkout, which holds the test's temporary folder.
    const plain = try repos.arena.print("/tmp/fx-capture-not-git-{d}", .{io_mod.nanoTimestamp()});
    try std.Io.Dir.cwd().createDirPath(testing.io, plain);
    defer std.Io.Dir.cwd().deleteTree(testing.io, plain) catch {};
    var request = repos.request(.{ .work_tree = plain, .git_dir = plain, .common_dir = plain }, "n", .{});
    request.path = plain;
    const outcome = try capture(repos.arena, request);
    try expectNotStored(outcome);
    try testing.expectEqual(Status.unavailable, outcome.status);
    try testing.expectEqual(policy.Reason.not_git, outcome.reason.?);
    try testing.expect(outcome.repository == null and outcome.head == .unknown and outcome.object_format == null);
}

test "capture store: every session id fx accepts names its own ref" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    const repo = try repos.repository("repo");
    const long = try repos.arena.alloc(u8, 255);
    @memset(long, 'z');
    var refs: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ "session.v3", "_-UIdxIkuoLH", long }) |id| {
        const outcome = try repos.captureRepo(repo, id);
        _ = try expectComplete(outcome);
        for (refs.items) |other| try testing.expect(!std.mem.eql(u8, other, outcome.ref.?));
        try refs.append(repos.arena, outcome.ref.?);
        try testing.expectEqualStrings(outcome.commit.?, (try repos.storeRef(repo, outcome.ref.?)).?);
    }
}

test "capture store: every folder the capture creates is private" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    const repo = try repos.repository("repo");
    _ = try expectStored(try repos.captureRepo(repo, "v"));
    const store_dir = try storeDir(repos.arena, repos.profile, repo.common_dir);
    const worktree_dir = try worktreeDir(repos.arena, store_dir, repo.git_dir);
    for ([_][]const u8{
        try std.Io.Dir.path.join(repos.arena, &.{ repos.profile, "captures" }),
        store_dir,
        try repos.store(repo),
        worktree_dir,
        try std.Io.Dir.path.join(repos.arena, &.{ worktree_dir, "scratch" }),
    }) |dir| {
        const stat = try std.Io.Dir.cwd().statFile(testing.io, dir, .{ .follow_symlinks = false });
        try testing.expectEqual(@as(std.posix.mode_t, 0o700), stat.permissions.toMode() & 0o777);
    }
}

test "capture store: a case-only rename on a case-insensitive disk matches the user's git" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    // Only a case-insensitive disk can hold the renamed file under both names.
    if (!try repos.exists("repo/A.TXT")) return error.SkipZigTest;
    const repo = try repos.repository("repo");
    try repos.rename("repo/a.txt", "repo/A.txt");
    const expected = try repos.expectedTree(repo, &.{});
    try testing.expectEqualStrings(expected, try expectComplete(try repos.captureRepo(repo, "case")));
}

test "capture store: another spelling of the same repository reaches the same store and ref" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    const repo = try repos.repository("repo");
    try repos.symlink(repos.root, "alias");
    const alias = try repos.path("alias");
    const spelled: Repository = .{
        .work_tree = try std.Io.Dir.path.join(repos.arena, &.{ alias, "repo" }),
        .git_dir = try std.Io.Dir.path.join(repos.arena, &.{ alias, "repo", ".git" }),
        .common_dir = try std.Io.Dir.path.join(repos.arena, &.{ alias, "repo", ".git" }),
    };
    const first = try repos.captureRepo(repo, "a");
    _ = try expectStored(first);
    try repos.append("repo/a.txt", "more\n");
    const second = try repos.captureRepo(spelled, "a");
    _ = try expectStored(second);
    try testing.expectEqualStrings(second.commit.?, (try repos.storeRef(repo, try repos.sessionRef(repo, "a"))).?);
    try testing.expectEqualStrings(first.commit.?, try repos.storeGit(repo, &.{ "rev-parse", try repos.arena.print("{s}^", .{second.commit.?}) }));
}

test "capture store: only what git treats as a nested repository is left out" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    // An empty `.git` folder is not a repository, and a repository started
    // inside a tracked folder does not hide its tracked files.
    try std.Io.Dir.cwd().createDirPath(testing.io, try repos.path("repo/plain/.git"));
    try repos.write("repo/plain/file.txt", "plain\n");
    _ = try repos.gitIn("repo/dir", &.{ "init", "-q", "-b", "main" });
    const repo = try repos.repository("repo");
    const expected = try repos.expectedTree(repo, &.{});
    const outcome = try repos.captureRepo(repo, "g");
    try testing.expectEqualStrings(expected, try expectComplete(outcome));
    try testing.expect(outcome.comparable);
}

test "capture store: precomposed Unicode with a non-ASCII untracked name lists with git" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    _ = try repos.gitIn("repo", &.{ "config", "core.precomposeUnicode", "true" });
    try repos.write("repo/caf\xc3\xa9.txt", "new\n");
    const repo = try repos.repository("repo");
    const expected = try repos.expectedTree(repo, &.{});
    const outcome = try repos.captureRepo(repo, "u");
    try testing.expectEqualStrings(expected, try expectComplete(outcome));
    try testing.expectEqual(@as(?Listing, .git), outcome.listing);
}

test "capture store: a store folder left without HEAD by an interrupted removal is replaced" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    const repo = try repos.repository("repo");
    try TestRepos.writeAbsolute(try std.Io.Dir.path.join(repos.arena, &.{ try repos.store(repo), "objects", "leftover" }), "x");
    const expected = try repos.expectedTree(repo, &.{});
    try testing.expectEqualStrings(expected, try expectComplete(try repos.captureRepo(repo, "h")));
    try testing.expect(!try TestRepos.existsAbsolute(try std.Io.Dir.path.join(repos.arena, &.{ try repos.store(repo), "objects", "leftover" })));
}

test "capture store: the partial reason is the most telling exclusion, whatever the paths' order" {
    const Ex = policy.Exclusion;
    try testing.expectEqual(@as(?policy.Reason, .inconsistent), lossReason(&[_]Ex{
        .{ .path = "a", .reason = .submodule },
        .{ .path = "b", .reason = .sensitive },
        .{ .path = "c", .reason = .missing },
    }));
    try testing.expectEqual(@as(?policy.Reason, .file_limit), lossReason(&[_]Ex{
        .{ .path = ".env", .reason = .sensitive },
        .{ .path = "z", .reason = .file_limit },
    }));
    try testing.expectEqual(@as(?policy.Reason, .sensitive), lossReason(&[_]Ex{
        .{ .path = "a", .reason = .submodule },
        .{ .path = "b", .reason = .sensitive },
    }));
    try testing.expectEqual(@as(?policy.Reason, null), lossReason(&[_]Ex{}));
}

const record_oid = "0123456789abcdef0123456789abcdef01234567";

fn parseRecord(bytes: []const u8) !std.json.Parsed(std.json.Value) {
    try testing.expect(std.mem.findScalar(u8, bytes, '\n') == null);
    try testing.expect(bytes.len <= 256 * 1024);
    return std.json.parseFromSlice(std.json.Value, testing.allocator, bytes, .{});
}

test "capture store: the record of a capture names its repository, ref, head and tree" {
    const outcome: Outcome = .{
        .status = .partial,
        .reason = .sensitive,
        .repository = .{ .work_tree = "/Users/example/repo", .git_dir = "/Users/example/repo/.git", .common_dir = "/Users/example/repo/.git" },
        .ref = "refs/fx/sessions/00/11",
        .head = .{ .commit = record_oid },
        .object_format = .sha1,
        .listing = .indexer,
        .index = .copied,
        .tree = record_oid,
        .commit = record_oid,
        .excluded = &.{.{ .path = ".env", .reason = .sensitive }},
    };
    const bytes = try encodeRecord(testing.allocator, .end, outcome);
    defer testing.allocator.free(bytes);
    const parsed = try parseRecord(bytes);
    defer parsed.deinit();
    const o = parsed.value.object;
    try testing.expectEqual(@as(i64, 1), o.get("v").?.integer);
    try testing.expectEqualStrings("end", o.get("phase").?.string);
    try testing.expectEqualStrings("partial", o.get("status").?.string);
    try testing.expectEqualStrings("sensitive", o.get("reason").?.string);
    try testing.expectEqualStrings("/Users/example/repo", o.get("work_tree").?.string);
    try testing.expectEqualStrings("refs/fx/sessions/00/11", o.get("ref").?.string);
    try testing.expectEqualStrings("commit", o.get("head_state").?.string);
    try testing.expectEqualStrings(record_oid, o.get("head").?.string);
    try testing.expectEqualStrings(record_oid, o.get("tree").?.string);
    try testing.expectEqualStrings("sha1", o.get("object_format").?.string);
    try testing.expectEqualStrings("indexer", o.get("listing").?.string);
    try testing.expectEqualStrings("copied", o.get("index").?.string);
    const excluded = o.get("excluded").?.object;
    try testing.expectEqual(@as(i64, 1), excluded.get("total").?.integer);
    try testing.expectEqual(@as(i64, 1), excluded.get("by_reason").?.object.get("sensitive").?.integer);
    try testing.expectEqualStrings(".env", excluded.get("sample").?.array.items[0].object.get("path").?.string);
}

test "capture store: a record never claims what the capture did not see" {
    // A failure before git ran: no repository, head, format or listing.
    const early = try encodeRecord(testing.allocator, .start, .{ .status = .unavailable, .reason = .not_git });
    defer testing.allocator.free(early);
    const parsed = try parseRecord(early);
    defer parsed.deinit();
    const o = parsed.value.object;
    try testing.expectEqualStrings("unknown", o.get("head_state").?.string);
    for ([_][]const u8{ "head", "tree", "commit", "object_format", "listing", "index", "work_tree", "ref" }) |field| {
        try testing.expectEqual(std.json.Value.null, o.get(field).?);
    }
    // A repository with no commit yet says so, apart from an unread HEAD.
    const unborn = try encodeRecord(testing.allocator, .start, .{ .status = .complete, .head = .unborn, .object_format = .sha1, .tree = record_oid, .commit = record_oid });
    defer testing.allocator.free(unborn);
    const born = try parseRecord(unborn);
    defer born.deinit();
    try testing.expectEqualStrings("unborn", born.value.object.get("head_state").?.string);
}

test "capture store: a record refuses an outcome that contradicts itself" {
    const invalid = [_]Outcome{
        .{ .status = .complete, .object_format = .sha1 },
        .{ .status = .complete, .reason = .timeout, .object_format = .sha1, .tree = record_oid, .commit = record_oid },
        .{ .status = .unavailable, .reason = .not_git, .object_format = .sha1, .tree = record_oid },
        .{ .status = .failed },
        .{ .status = .partial, .object_format = .sha1, .tree = record_oid, .commit = record_oid },
        .{ .status = .partial, .reason = .not_git, .object_format = .sha1, .tree = record_oid, .commit = record_oid },
        .{ .status = .unavailable, .reason = .sensitive },
        .{ .status = .failed, .reason = .file_limit },
        .{ .status = .complete, .object_format = .sha1, .tree = "not-an-oid", .commit = record_oid },
        .{ .status = .complete, .object_format = .sha256, .tree = record_oid, .commit = record_oid },
        .{ .status = .complete, .tree = record_oid, .commit = record_oid },
        .{ .status = .failed, .reason = .io_error, .head = .{ .commit = "zz" }, .object_format = .sha1 },
    };
    for (invalid) |outcome| try testing.expectError(error.InvalidOutcome, encodeRecord(testing.allocator, .end, outcome));
    const valid = [_]Outcome{
        .{ .status = .failed, .reason = .io_error },
        .{ .status = .failed, .reason = .invalid_request },
        .{ .status = .failed, .reason = .inconsistent },
        .{ .status = .unavailable, .reason = .budget },
        .{ .status = .unavailable, .reason = .capture_locked },
        .{ .status = .partial, .reason = .budget, .object_format = .sha1, .tree = record_oid, .commit = record_oid },
        .{ .status = .partial, .reason = .untracked_timeout, .object_format = .sha1, .tree = record_oid, .commit = record_oid },
    };
    for (valid) |outcome| {
        const bytes = try encodeRecord(testing.allocator, .end, outcome);
        testing.allocator.free(bytes);
    }
}

test "capture store: a record of thousands of exclusions and names that are not UTF-8 stays one small JSON line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var excluded: std.ArrayList(policy.Exclusion) = .empty;
    try excluded.append(arena, .{ .path = "caf\xe9.txt", .reason = .file_limit });
    try excluded.append(arena, .{ .path = "\xff\xfe", .reason = .sensitive });
    for (0..5000) |i| {
        const long = try arena.alloc(u8, 4000);
        @memset(long, 'p');
        try excluded.append(arena, .{ .path = try arena.print("{d}/{s}", .{ i, long }), .reason = .file_limit });
    }
    const bytes = try encodeRecord(testing.allocator, .end, .{
        .status = .partial,
        .reason = .file_limit,
        .object_format = .sha1,
        .tree = record_oid,
        .commit = record_oid,
        .excluded = excluded.items,
    });
    defer testing.allocator.free(bytes);
    try testing.expect(bytes.len <= max_sample_bytes + 4096);
    const parsed = try parseRecord(bytes);
    defer parsed.deinit();
    const out = parsed.value.object.get("excluded").?.object;
    try testing.expectEqual(@as(i64, 5002), out.get("total").?.integer);
    try testing.expectEqual(@as(i64, 5001), out.get("by_reason").?.object.get("file_limit").?.integer);
    try testing.expect(out.get("sample_truncated").?.bool);
    const sample = out.get("sample").?.array.items;
    try testing.expect(sample.len >= 2 and sample.len <= max_sample_paths);
    try testing.expectEqualStrings("636166e92e747874", sample[0].object.get("path_hex").?.string);
    try testing.expectEqual(std.json.Value.null, sample[0].object.get("path").?);
    try testing.expectEqualStrings("fffe", sample[1].object.get("path_hex").?.string);
}

fn encodeRecordCase(alloc: Allocator) !void {
    const bytes = try encodeRecord(alloc, .start, .{
        .status = .partial,
        .reason = .sensitive,
        .object_format = .sha1,
        .tree = record_oid,
        .commit = record_oid,
        .excluded = &.{ .{ .path = ".env", .reason = .sensitive }, .{ .path = "\xff", .reason = .file_limit } },
    });
    alloc.free(bytes);
}

test "capture store: encoding a record releases its memory at every failure point" {
    try testing.checkAllAllocationFailures(@import("../shared/testing_allocator.zig").no_resize, encodeRecordCase, .{});
}

test "capture store: a capture over the untracked limit encodes into a record the session takes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    for (0..1200) |i| try repos.write(try repos.arena.print("repo/many/{d:0>4}.txt", .{i}), "x\n");
    const repo = try repos.repository("repo");
    const outcome = try repos.captureRepo(repo, "big");
    _ = try expectStored(outcome);
    try testing.expectEqual(Status.partial, outcome.status);
    const bytes = try encodeRecord(testing.allocator, .end, outcome);
    defer testing.allocator.free(bytes);
    const parsed = try parseRecord(bytes);
    defer parsed.deinit();
    const out = parsed.value.object.get("excluded").?.object;
    try testing.expectEqual(@as(i64, @intCast(outcome.excluded.len)), out.get("total").?.integer);
    try testing.expect(out.get("by_reason").?.object.get("file_limit").?.integer > 0);
}

test "capture store: credential files are left out whatever their case, and an ordinary config.json is kept" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.initRepo("secrets");
    try repos.write("secrets/readme.txt", "readme\n");
    _ = try repos.gitIn("secrets", &.{ "add", "-A" });
    try repos.commit("secrets", "base");
    const sensitive = [_][]const u8{ ".ENV", "ID_RSA", "Credentials", ".docker/config.json", ".aws/credentials" };
    for (sensitive) |name| try repos.write(try repos.in("secrets", name), "SECRET=1\n");
    try repos.write("secrets/config.json", "{}\n");
    const repo = try repos.repository("secrets");
    const expected = try repos.expectedTree(repo, &sensitive);

    const outcome = try repos.captureRepo(repo, "secrets");
    const tree = try expectStored(outcome);
    try testing.expectEqualStrings(expected, tree);
    try testing.expectEqual(Status.partial, outcome.status);
    try testing.expectEqual(policy.Reason.sensitive, outcome.reason.?);
    for (sensitive) |name| {
        try expectExcluded(outcome, name, .sensitive);
        try testing.expect(!try repos.treeHas(repo, tree, name));
    }
    try testing.expectEqual(sensitive.len, outcome.excluded.len);
    try testing.expectEqualStrings("{}", try repos.storedFile(repo, tree, "config.json"));
}

test "capture store: the untracked listing reports untracked_timeout at once when the deadline has passed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.initRepo("repo");
    try repos.write("repo/new.txt", "new\n");
    const repo = try repos.repository("repo");
    const ready = switch (try safe_git.prepareWithin(repos.arena, repo.work_tree, .{})) {
        .ready => |value| value,
        .refused => return error.TestUnexpectedRefusal,
    };
    const facts = (try safe_git.repositoryFacts(repos.arena, ready, repo.work_tree, .{})) orelse return error.TestExpectedFacts;
    var tracked: std.StringHashMapUnmanaged(Staged) = .empty;
    var outcome: Outcome = .{ .status = .complete };

    // Control: with time left, the indexer lists the new file.
    const later: std.Io.Clock.Timestamp = .fromNow(testing.io, .{ .clock = .awake, .raw = .fromMilliseconds(test_deadline_ms) });
    const listed = try listUntracked(repos.arena, testing.allocator, ready, facts, later, &tracked, &outcome);
    try testing.expect(listed == .listed);
    try testing.expectEqual(@as(?Listing, .indexer), outcome.listing);

    const expired: std.Io.Clock.Timestamp = .fromNow(testing.io, .{ .clock = .awake, .raw = .fromMilliseconds(-1) });
    const started: std.Io.Clock.Timestamp = .now(testing.io, .awake);
    outcome = .{ .status = .complete };
    const stopped = try listUntracked(repos.arena, testing.allocator, ready, facts, expired, &tracked, &outcome);
    const took_ms = started.durationTo(.now(testing.io, .awake)).raw.toMilliseconds();
    try testing.expect(stopped == .stopped);
    try testing.expect(outcome.listing == null);
    try testing.expect(took_ms < 200);
    // The record of such a capture is accepted as unavailable.
    const record = try encodeRecord(testing.allocator, .start, withFailure(outcome, .unavailable, .untracked_timeout));
    testing.allocator.free(record);
}

test "capture store: a .git that is a symlink or a gitdir file into another repository is unavailable as foreign_git_dir" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("other");
    const other = try repos.repository("other");
    try repos.write("linked/mine.txt", "mine\n");
    try repos.symlink(try std.Io.Dir.path.join(repos.arena, &.{ other.work_tree, ".git" }), "linked/.git");
    try repos.write("pointer/mine.txt", "mine\n");
    try repos.write("pointer/.git", try repos.arena.print("gitdir: {s}/.git\n", .{other.work_tree}));
    const before = try repos.userState(other);

    for ([_][]const u8{ "linked", "pointer" }) |name| {
        const folder = try io_mod.realpathAlloc(repos.arena, try repos.path(name));
        const outcome = try capture(repos.arena, repos.request(.{ .work_tree = folder, .git_dir = "", .common_dir = "" }, "foreign", .{}));
        try expectNotStored(outcome);
        try testing.expectEqual(Status.unavailable, outcome.status);
        try testing.expectEqual(policy.Reason.foreign_git_dir, outcome.reason.?);
        // Nothing of the other repository is claimed.
        try testing.expect(outcome.head == .unknown);
        try testing.expect(outcome.ref == null);
        try testing.expect(outcome.repository == null);
        const record = try encodeRecord(testing.allocator, .start, outcome);
        testing.allocator.free(record);
    }
    try testing.expectEqualStrings("", try repos.storeRefs(other));
    try testing.expectEqualStrings(before, try repos.userState(other));

    // A separate git directory is the folder's own and still captures.
    try std.Io.Dir.cwd().createDirPath(testing.io, try repos.path("separate"));
    _ = try repos.gitIn("separate", &.{ "init", "-q", "-b", "main", "--separate-git-dir", try repos.path("separate-git") });
    try repos.write("separate/a.txt", "a\n");
    const separate = try repos.repository("separate");
    _ = try expectComplete(try repos.captureRepo(separate, "own"));
}

test "capture store: creating the store runs on its own budget, so a slow first setup still captures" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeShapes("repo");
    try repos.write("repo/new.txt", "new\n");
    const repo = try repos.repository("repo");
    // Another process holds the store's `init.lock` past the capture's own
    // deadline, as a slow store creation would take that time.
    const store_dir = try storeDir(repos.arena, repos.profile, repo.common_dir);
    try std.Io.Dir.cwd().createDirPath(testing.io, store_dir);
    const held = try std.Io.Dir.createFileAbsolute(testing.io, try std.Io.Dir.path.join(repos.arena, &.{ store_dir, "init.lock" }), .{ .truncate = false, .read = true });
    try testing.expect(try held.tryLock(testing.io, .exclusive));
    const Release = struct {
        fn run(file: std.Io.File) void {
            io_mod.sleep(2000 * std.time.ns_per_ms);
            file.close(testing.io);
        }
    };
    const releaser = try std.Thread.spawn(.{}, Release.run, .{held});
    defer releaser.join();

    var request = repos.request(repo, "setup", .{});
    request.deadline = .fromNow(testing.io, .{ .clock = .awake, .raw = .fromMilliseconds(1500) });
    const outcome = try capture(repos.arena, request);
    _ = try expectComplete(outcome);
    try testing.expectEqual(@as(?IndexStart, .copied), outcome.index);
    try testing.expect(try repos.treeHas(repo, outcome.tree.?, "new.txt"));
}

test "capture store: copying a session's refs keeps its captures for the copy after the original's are gone" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.makeTwoWorktrees();
    const main_repo = try repos.repository("wt-main");
    const side_repo = try repos.repository("wt-side");
    try repos.makeShapes("solo");
    const solo = try repos.repository("solo");
    const captured = [_]struct { Repository, Outcome }{
        .{ main_repo, try repos.captureRepo(main_repo, "A") },
        .{ side_repo, try repos.captureRepo(side_repo, "A") },
        .{ solo, try repos.captureRepo(solo, "A") },
    };
    for (captured) |entry| _ = try expectStored(entry[1]);
    // A session with captures of its own is never touched.
    _ = try expectStored(try repos.captureRepo(solo, "other"));
    const other_before = (try repos.storeRef(solo, try repos.sessionRef(solo, "other"))).?;

    const copy_request: CopyRequest = .{
        .profile_root = repos.profile,
        .from_session_id = "A",
        .to_session_id = "B",
        .deadline = .fromNow(testing.io, .{ .clock = .awake, .raw = .fromMilliseconds(test_deadline_ms) }),
    };
    const first = try copySessionRefs(repos.arena, copy_request);
    try testing.expectEqual(CopyResult{ .copied = 3 }, first);
    for (captured) |entry| {
        try testing.expectEqualStrings(entry[1].commit.?, (try repos.storeRef(entry[0], try repos.sessionRef(entry[0], "A"))).?);
        try testing.expectEqualStrings(entry[1].commit.?, (try repos.storeRef(entry[0], try repos.sessionRef(entry[0], "B"))).?);
    }
    // A second run changes nothing.
    try testing.expectEqual(CopyResult{ .existing = 3 }, try copySessionRefs(repos.arena, copy_request));
    try testing.expectError(error.InvalidRequest, copySessionRefs(repos.arena, .{ .profile_root = repos.profile, .from_session_id = "A", .to_session_id = "A", .deadline = copy_request.deadline }));
    try testing.expectError(error.InvalidRequest, copySessionRefs(repos.arena, .{ .profile_root = repos.profile, .from_session_id = "../A", .to_session_id = "B", .deadline = copy_request.deadline }));

    // The original's refs go and the stores are pruned: the copy still
    // names commits whose trees restore.
    for (captured) |entry| {
        _ = try repos.storeGit(entry[0], &.{ "update-ref", "-d", try repos.sessionRef(entry[0], "A") });
    }
    _ = try repos.storeGit(main_repo, &.{ "gc", "--quiet", "--prune=now" });
    _ = try repos.storeGit(solo, &.{ "gc", "--quiet", "--prune=now" });
    for (captured) |entry| {
        try testing.expect(try repos.storeRef(entry[0], try repos.sessionRef(entry[0], "A")) == null);
        try testing.expectEqualStrings("commit", try repos.storeGit(entry[0], &.{ "cat-file", "-t", try repos.sessionRef(entry[0], "B") }));
        try testing.expectEqualStrings(entry[1].tree.?, try repos.storeGit(entry[0], &.{ "rev-parse", try repos.arena.print("{s}^{{tree}}", .{try repos.sessionRef(entry[0], "B")}) }));
    }
    try testing.expectEqualStrings("one", try repos.storedFile(solo, captured[2][1].tree.?, "a.txt"));
    try testing.expectEqualStrings(other_before, (try repos.storeRef(solo, try repos.sessionRef(solo, "other"))).?);
}

// Not part of the suite: set `FX_CAPTURE_MEASURE_FILES`, such as to
// 150000, to time a capture of that many untracked files against a 2 s
// deadline, or `FX_CAPTURE_MEASURE_DEADLINE_MS`. The capture must return
// within about the deadline.
test "capture store: manual measurement of a capture over many untracked files" {
    if (!builtin.link_libc) return error.SkipZigTest;
    const raw = std.c.getenv("FX_CAPTURE_MEASURE_FILES") orelse return error.SkipZigTest;
    const count = std.fmt.parseInt(usize, std.mem.span(raw), 10) catch return error.SkipZigTest;
    const deadline_ms: i64 = if (std.c.getenv("FX_CAPTURE_MEASURE_DEADLINE_MS")) |text| std.fmt.parseInt(i64, std.mem.span(text), 10) catch 2000 else 2000;
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const repos = try TestRepos.init(arena_state.allocator(), tmp.dir);
    defer repos.deinit();
    try repos.initRepo("big");
    try repos.write("big/tracked.txt", "tracked\n");
    _ = try repos.gitIn("big", &.{ "add", "-A" });
    try repos.commit("big", "base");
    var folder = try std.Io.Dir.cwd().openDir(testing.io, try repos.path("big"), .{});
    defer folder.close(testing.io);
    var name_buf: [64]u8 = undefined;
    for (0..count) |i| {
        if (i % 1000 == 0) try folder.createDirPath(testing.io, try std.mem.print(&name_buf, "d{d}", .{i / 1000}));
        const name = try std.mem.print(&name_buf, "d{d}/f{d}.txt", .{ i / 1000, i });
        try folder.writeFile(testing.io, .{ .sub_path = name, .data = "x\n" });
    }
    const repo = try repos.repository("big");
    // The first capture creates the store on its own budget; the second
    // measures a capture into a store that exists.
    for ([_][]const u8{ "first", "second" }) |label| {
        var request = repos.request(repo, "measure", .{});
        request.deadline = .fromNow(testing.io, .{ .clock = .awake, .raw = .fromMilliseconds(deadline_ms) });
        const started: std.Io.Clock.Timestamp = .now(testing.io, .awake);
        const outcome = try capture(repos.arena, request);
        const took = started.durationTo(.now(testing.io, .awake)).raw.toMilliseconds();
        const reason = if (outcome.reason) |value| @tagName(value) else "none";
        const listing = if (outcome.listing) |value| @tagName(value) else "none";
        std.debug.print("measure {s}: files={d} deadline_ms={d} ms={d} status={s} reason={s} listing={s}\n", .{ label, count, deadline_ms, took, @tagName(outcome.status), reason, listing });
    }
}
