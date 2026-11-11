//! The one way fx runs git itself: the `fx pr` and `fx issue` snapshot, the
//! agent's auto-run `git status`, `git diff` and `git log`, and the workspace
//! capture route into an fx-owned store (not yet called). A repository's own
//! config can name programs: fsmonitor, hooks, a pager, diff drivers, filter
//! drivers and a signature verifier. Every invocation turns those off, while
//! the user's global and system config stay trusted, so a global Git LFS still
//! works. When fx cannot establish that, `prepare` refuses and git does not run.
//!
//! TLA+ model: `tests/tla/shell_command/GitAdmission.tla`.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const indexer = @import("../indexer/indexer.zig");
const repo_path = @import("../shared/repo_path.zig");

const Allocator = std.mem.Allocator;

/// The oldest git these settings were checked against with planted programs
/// for every route: 2.25.1, 2.34.1 and 2.54.0. `core.fsmonitor` became a
/// boolean in git 2.36; older git runs the value as a hook command, and the
/// fixed PATH resolves `false` to the system `false`, which does nothing.
const minimum_major: u32 = 2;
const minimum_minor: u32 = 25;
/// The capture route needs `init --object-format` and `rev-parse
/// --show-object-format`, both from git 2.29.
const store_minimum_minor: u32 = 29;

const max_probe_output: usize = 4096;

pub const Refusal = enum {
    git_missing,
    git_version_unknown,
    git_too_old,
    repo_config_unavailable,
    /// `-c` splits at the first `=`, so such a driver cannot be blanked.
    unsupported_filter_name,
    /// git would use a different repository than the one whose config fx read.
    repository_mismatch,
};

pub const Ready = struct {
    /// Static path from `trustedExecutable`.
    executable: []const u8,
    /// Filter drivers defined by repository-scope config.
    filter_names: []const []const u8,
    /// The git directory fx's discovery found for the directory, without
    /// running git; null when no repository holds it.
    git_dir: ?[]const u8 = null,
};

pub const Prepared = union(enum) {
    ready: Ready,
    refused: Refusal,
};

pub const Subcommand = enum { status, diff, log, branch, rev_parse };

/// Decides whether git may run in the absolute directory `cwd`: reads the
/// repository's config as data, checks the trusted git's version once per
/// process, and confirms git resolves the same repository fx read. All memory
/// belongs to `arena`.
pub fn prepare(arena: Allocator, cwd: []const u8) Allocator.Error!Prepared {
    return prepareWithin(arena, cwd, null);
}

/// `prepare` whose own git runs, the version check and `rev-parse`, stop at
/// `limits`' deadline, for a caller with one budget for all its work.
pub fn prepareWithin(arena: Allocator, cwd: []const u8, limits: ?Limits) Allocator.Error!Prepared {
    const filters = indexer.repoFilters(arena, cwd) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.RepoConfigUnavailable => return refuse(.repo_config_unavailable, cwd),
    };
    for (filters.names) |name| {
        if (name.len == 0 or std.mem.findScalar(u8, name, '=') != null) return refuse(.unsupported_filter_name, cwd);
    }
    const executable = trustedExecutable() orelse return refuse(.git_missing, cwd);
    switch (try versionCheckAtLeast(arena, executable, minimum_minor, limits)) {
        .supported => {},
        .too_old => return refuse(.git_too_old, cwd),
        .unknown => return refuse(.git_version_unknown, cwd),
    }
    const ready: Ready = .{ .executable = executable, .filter_names = filters.names, .git_dir = filters.git_dir };
    if (!try sameRepository(arena, ready, cwd, filters.git_dir, limits)) return refuse(.repository_mismatch, cwd);
    return .{ .ready = ready };
}

fn refuse(reason: Refusal, cwd: []const u8) Prepared {
    debug_trace.logf("core", "safe git refused reason={s} cwd={s}", .{ @tagName(reason), cwd });
    return .{ .refused = reason };
}

/// Appends the trusted executable, the global options and `-c` overrides that
/// turn off repository programs, then `subcommand` with its own safety flags.
/// Callers append the remaining arguments. Formatted overrides are allocated
/// with `arena`; the other strings are static or borrowed from `ready`.
pub fn appendCommand(
    arena: Allocator,
    argv: *std.ArrayList([]const u8),
    ready: Ready,
    subcommand: Subcommand,
) Allocator.Error!void {
    try appendPrelude(arena, argv, ready);
    try argv.appendSlice(arena, switch (subcommand) {
        .status => &.{ "status", "--ignore-submodules=all" },
        .diff => &.{ "diff", "--no-ext-diff", "--no-textconv", "--ignore-submodules=all" },
        .log => &.{ "log", "--no-ext-diff", "--no-textconv", "--ignore-submodules=all" },
        .branch => &.{"branch"},
        .rev_parse => &.{"rev-parse"},
    });
}

fn appendPrelude(arena: Allocator, argv: *std.ArrayList([]const u8), ready: Ready) Allocator.Error!void {
    try argv.appendSlice(arena, &.{
        ready.executable,
        "--no-pager",
        "--no-optional-locks",
        "-c",
        "core.fsmonitor=false",
        "-c",
        "core.hooksPath=/dev/null",
        "-c",
        "log.showSignature=false",
    });
    for (ready.filter_names) |name| {
        for ([_][]const u8{ "clean", "smudge", "process" }) |program| {
            try argv.append(arena, "-c");
            try argv.append(arena, try arena.print("filter.{s}.{s}=", .{ name, program }));
        }
    }
}

/// The child environment for every safe git call: a fixed PATH and locale, no
/// prompts, pagers or optional locks, and only the variables that locate the
/// user's own git config. Nothing else from fx's environment, such as
/// `GIT_DIR` or `GIT_CONFIG_PARAMETERS`, reaches git.
pub fn environment(alloc: Allocator) Allocator.Error!std.process.Environ.Map {
    var map = std.process.Environ.Map.init(alloc);
    errdefer map.deinit();
    try map.put("PATH", "/usr/bin:/bin");
    try map.put("LC_ALL", "C");
    try map.put("LANG", "C");
    try map.put("GIT_OPTIONAL_LOCKS", "0");
    try map.put("GIT_TERMINAL_PROMPT", "0");
    try map.put("GIT_PAGER", "cat");
    try map.put("PAGER", "cat");
    for ([_][]const u8{ "HOME", "XDG_CONFIG_HOME", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "GIT_CONFIG_NOSYSTEM" }) |key| {
        if (io_mod.getenv(key)) |value| try map.put(key, value);
    }
    return map;
}

/// The first git found at a fixed system location. git from PATH is never
/// used, because PATH can include directories a repository controls.
fn trustedExecutable() ?[]const u8 {
    const candidates = switch (builtin.target.os.tag) {
        .windows => &[_][]const u8{
            "C:\\Program Files\\Git\\cmd\\git.exe",
            "C:\\Program Files\\Git\\bin\\git.exe",
        },
        else => &[_][]const u8{
            "/usr/bin/git",
            "/bin/git",
            "/usr/local/bin/git",
            "/opt/homebrew/bin/git",
            "/opt/local/bin/git",
            "/run/current-system/sw/bin/git",
        },
    };
    for (candidates) |candidate| {
        const stat = std.Io.Dir.cwd().statFile(io_mod.getIo(), candidate, .{ .follow_symlinks = true }) catch continue;
        if (stat.kind == .file) return candidate;
    }
    return null;
}

const VersionCheck = enum { supported, too_old, unknown };

var version_lock: std.Io.Mutex = .init;
var cached_version: ?struct { executable: []const u8, output: [64]u8, len: usize } = null;

/// Runs `git --version` once per executable and process. A failed probe is not
/// cached, so a transient spawn failure does not disable git for the session.
fn versionCheckAtLeast(arena: Allocator, executable: []const u8, min_minor: u32, limits: ?Limits) Allocator.Error!VersionCheck {
    const io = io_mod.getIo();
    version_lock.lockUncancelable(io);
    defer version_lock.unlock(io);
    if (cached_version) |*cached| {
        if (std.mem.eql(u8, cached.executable, executable)) return classifyVersionAtLeast(cached.output[0..cached.len], min_minor);
    }
    const output = try runCaptured(arena, &.{ executable, "--version" }, "/", limits) orelse return .unknown;
    var entry: @TypeOf(cached_version.?) = .{ .executable = executable, .output = undefined, .len = @min(output.len, 64) };
    @memcpy(entry.output[0..entry.len], output[0..entry.len]);
    cached_version = entry;
    return classifyVersionAtLeast(output, min_minor);
}

fn classifyVersion(output: []const u8) VersionCheck {
    return classifyVersionAtLeast(output, minimum_minor);
}

fn classifyVersionAtLeast(output: []const u8, min_minor: u32) VersionCheck {
    const prefix = "git version ";
    if (!std.mem.startsWith(u8, output, prefix)) return .unknown;
    var parts = std.mem.splitScalar(u8, output[prefix.len..], '.');
    const major = leadingNumber(parts.next() orelse "") orelse return .unknown;
    const minor = leadingNumber(parts.next() orelse "") orelse return .unknown;
    if (major != minimum_major) return if (major > minimum_major) .supported else .too_old;
    return if (minor >= min_minor) .supported else .too_old;
}

fn leadingNumber(text: []const u8) ?u32 {
    var end: usize = 0;
    while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
    if (end == 0) return null;
    return std.fmt.parseUnsigned(u32, text[0..end], 10) catch null;
}

/// Confirms git resolves the repository whose config fx read. git accepts a
/// git directory used as the workspace, and fx's discovery does not, so
/// without this check git could run with config fx never read. `rev-parse`
/// reads config but runs none of the programs above.
fn sameRepository(arena: Allocator, ready: Ready, cwd: []const u8, expected: ?[]const u8, limits: ?Limits) Allocator.Error!bool {
    var argv: std.ArrayList([]const u8) = .empty;
    try appendCommand(arena, &argv, ready, .rev_parse);
    try argv.append(arena, "--absolute-git-dir");
    const output = try runCaptured(arena, argv.items, cwd, limits);
    const expected_dir = expected orelse return output == null;
    const reported = std.mem.trimEnd(u8, output orelse return false, "\r\n");
    const expected_real = io_mod.realpathAlloc(arena, expected_dir) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    const reported_real = io_mod.realpathAlloc(arena, reported) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    return std.mem.eql(u8, expected_real, reported_real);
}

/// Standard output of a successful run, or null when git could not start,
/// failed, or ran past `limits`' deadline. Memory belongs to `arena`.
fn runCaptured(arena: Allocator, argv: []const []const u8, cwd: []const u8, limits: ?Limits) Allocator.Error!?[]const u8 {
    var env = try environment(arena);
    if (limits) |bounded| {
        var probe = bounded;
        probe.max_stdout = max_probe_output;
        return switch (try runBounded(arena, argv, cwd, &env, null, null, probe)) {
            .ok => |stdout| stdout,
            .failed => null,
        };
    }
    const result = std.process.run(arena, io_mod.getIo(), .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .environ_map = &env,
        .stdout_limit = .limited(max_probe_output),
        .stderr_limit = .limited(max_probe_output),
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    return switch (result.term) {
        .exited => |code| if (code == 0) result.stdout else null,
        else => null,
    };
}

// Workspace capture route. Captures write objects only into an fx-owned bare
// store whose config fx created; the user's repository config is never read
// there. `GIT_DIR`, the capture index and the work tree are set explicitly, so
// git does not discover the user's `.git`. Every command is typed: there is no
// pass-through of arbitrary arguments. Global and system config stay trusted,
// so a worktree `.gitattributes` can still select a filter they define.

/// Bounds for one capture git command. `deadline`, when set, replaces
/// `timeout_ms`, so a whole capture can share one budget.
pub const Limits = struct {
    timeout_ms: i64 = 2000,
    deadline: ?std.Io.Clock.Timestamp = null,
    max_stdout: usize = 64 * 1024 * 1024,
};

const max_capture_stderr: usize = 1024 * 1024;

pub const Failure = enum {
    spawn_failed,
    input_failed,
    read_failed,
    timeout,
    cancelled,
    output_too_large,
    exited_nonzero,
    terminated,
    /// git exited 0 but dropped a path it would not record.
    path_rejected,
};

pub const Outcome = union(enum) {
    /// Standard output, owned by the arena.
    ok: []const u8,
    failed: Failure,
};

/// The trusted git, checked without reading any repository. Distinct from
/// `Ready` so a store handle cannot reach a route that must blank the
/// repository's own filters.
pub const StoreReady = struct { executable: []const u8 };

pub const PreparedStore = union(enum) {
    ready: StoreReady,
    refused: Refusal,
};

pub const ObjectFormat = enum { sha1, sha256 };

/// Content conversion settings copied from the user's repository, so the
/// store records the same tree the user's git would. Null leaves global
/// config in charge.
pub const Conversions = struct {
    file_mode: ?bool = null,
    symlinks: ?bool = null,
    autocrlf: ?enum { true, false, input } = null,
    eol: ?enum { lf, crlf, native } = null,
};

/// Absolute paths for one capture. `scratch_dir` must exist and be private.
pub const Store = struct {
    git_dir: []const u8,
    index_file: []const u8,
    work_tree: []const u8,
    scratch_dir: []const u8,
    conversions: Conversions = .{},
};

/// The kind of an index entry, as git writes it in octal.
pub const EntryMode = enum {
    file,
    executable,
    symlink,
    gitlink,

    fn text(mode: EntryMode) []const u8 {
        return switch (mode) {
            .file => "100644",
            .executable => "100755",
            .symlink => "120000",
            .gitlink => "160000",
        };
    }

    fn parse(octal: []const u8) ?EntryMode {
        for ([_]EntryMode{ .file, .executable, .symlink, .gitlink }) |mode| {
            if (std.mem.eql(u8, octal, mode.text())) return mode;
        }
        return null;
    }
};

pub const IndexEntry = struct {
    mode: EntryMode,
    oid: []const u8,
    path: []const u8,
};

/// One entry of `ls-files -z --stage -v`, as the capture reads it.
pub const StagedEntry = struct {
    path: []const u8,
    mode: EntryMode,
    oid: []const u8,
    assume_unchanged: bool,
    skip_worktree: bool,
};

/// Parses `ls-files -z --stage -v`: `<tag> <mode> <oid> <stage>\t<path>`.
/// Unmerged paths appear once per stage and collapse to one entry. Entries
/// borrow `listing`; the list belongs to `arena`.
pub fn parseStageListing(arena: Allocator, listing: []const u8) error{ OutOfMemory, Malformed }![]const StagedEntry {
    var entries: std.ArrayList(StagedEntry) = .empty;
    var records = std.mem.splitScalar(u8, listing, 0);
    while (records.next()) |record| {
        if (record.len == 0) continue;
        const tab = std.mem.findScalar(u8, record, '\t') orelse return error.Malformed;
        var fields = std.mem.splitScalar(u8, record[0..tab], ' ');
        const tag = fields.next() orelse return error.Malformed;
        const mode_text = fields.next() orelse return error.Malformed;
        const oid = fields.next() orelse return error.Malformed;
        _ = fields.next() orelse return error.Malformed;
        if (tag.len != 1 or fields.next() != null) return error.Malformed;
        const path = record[tab + 1 ..];
        if (path.len == 0) return error.Malformed;
        if (entries.items.len > 0 and std.mem.eql(u8, entries.items[entries.items.len - 1].path, path)) continue;
        try entries.append(arena, .{
            .path = path,
            .mode = EntryMode.parse(mode_text) orelse return error.Malformed,
            .oid = oid,
            .assume_unchanged = std.ascii.isLower(tag[0]),
            .skip_worktree = std.ascii.toUpper(tag[0]) == 'S',
        });
    }
    return entries.items;
}

pub const StoreCommand = union(enum) {
    /// Loads a tree into the capture index; null empties it.
    read_tree: ?[]const u8,
    /// Adds, refreshes or removes these worktree paths in the capture index.
    /// A path still on disk is kept: `--remove` only drops missing files.
    add_remove: []const []const u8,
    /// Drops these paths from the capture index even when they exist on disk,
    /// such as an untracked file that became ignored.
    force_remove: []const []const u8,
    /// Clears one flag in the capture index only. git applies just the first
    /// of `--no-assume-unchanged` and `--no-skip-worktree` to each path, so
    /// each flag is its own command.
    clear_flag: struct { flag: enum { assume_unchanged, skip_worktree }, paths: []const []const u8 },
    /// Sets entries to the given mode and object without reading the worktree.
    index_info: []const IndexEntry,
    write_tree,
    commit_tree: struct { tree: []const u8, parent: ?[]const u8, message: []const u8, unix_seconds: i64 },
    /// Compare-and-swap; a null `old` requires that the ref does not exist.
    update_ref: struct { ref: []const u8, new: []const u8, old: ?[]const u8 },
    /// `ls-files -z --stage -v` of the capture index: the same format as
    /// `Listing.tracked`, so inherited flags show.
    list_index,
    /// The object a capture ref names, or empty output when it does not exist.
    resolve_ref: []const u8,
    /// Every capture ref, one `<ref> <object> <unix seconds>` line each; the
    /// time is the newest capture's.
    list_refs,
    /// Deletes a capture ref only while it still names `old`, so a capture
    /// that just moved it keeps it.
    delete_ref: struct { ref: []const u8, old: []const u8 },
    /// Packs the store and prunes every unreachable object at once. Only
    /// for a caller that holds every capture lock of the store, so no
    /// capture has written objects it has not yet named.
    gc,
};

pub const Listing = enum {
    /// `ls-files -z --stage -v`: lowercase tags mark assume-unchanged, `S`
    /// marks skip-worktree.
    tracked,
    untracked,
};

pub const StoreError = Allocator.Error || error{InvalidArgument};

const capture_ref_prefix = "refs/fx/sessions/";
const capture_identity_name = "fx capture";
const capture_identity_email = "capture@fx.invalid";
/// Whether git runs in its own process group fx can signal. WASI and
/// freestanding builds, such as the libfx WebAssembly core, have no processes.
const has_process_groups = switch (builtin.target.os.tag) {
    .windows, .wasi, .freestanding => false,
    else => true,
};
/// The capture route's PATH: the system directories plus the fixed places
/// `trustedExecutable` already trusts for git itself. A filter that global or
/// system config names by bare command, such as Homebrew's `git-lfs`, then
/// resolves; the store's own config names none.
const capture_path = "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin:/opt/local/bin:/run/current-system/sw/bin";

var input_counter: std.atomic.Value(u32) = .init(0);

pub fn prepareStore(arena: Allocator, limits: Limits) Allocator.Error!PreparedStore {
    const executable = trustedExecutable() orelse return .{ .refused = refuse(.git_missing, "store").refused };
    return switch (try versionCheckAtLeast(arena, executable, store_minimum_minor, limits)) {
        .supported => .{ .ready = .{ .executable = executable } },
        .too_old => .{ .refused = refuse(.git_too_old, "store").refused },
        .unknown => .{ .refused = refuse(.git_version_unknown, "store").refused },
    };
}

/// Creates the bare store without templates, so it has no hooks, in the
/// object format of the repository whose objects it borrows.
pub fn initStore(arena: Allocator, ready: StoreReady, git_dir: []const u8, format: ObjectFormat, limits: Limits) StoreError!Outcome {
    var base = try environment(arena);
    return initStoreWith(arena, ready, git_dir, format, limits, &base);
}

fn initStoreWith(
    arena: Allocator,
    ready: StoreReady,
    git_dir: []const u8,
    format: ObjectFormat,
    limits: Limits,
    base: *std.process.Environ.Map,
) StoreError!Outcome {
    if (!std.Io.Dir.path.isAbsolute(git_dir)) return error.InvalidArgument;
    var argv: std.ArrayList([]const u8) = .empty;
    try appendStorePrelude(arena, &argv, ready, .{});
    try argv.appendSlice(arena, &.{ "init", "-q", "--bare", "--template=", switch (format) {
        .sha1 => "--object-format=sha1",
        .sha256 => "--object-format=sha256",
    }, git_dir });
    return runBounded(arena, argv.items, "/", base, null, null, limits);
}

/// Runs one typed command against the capture store. Memory belongs to
/// `arena`.
pub fn runStore(arena: Allocator, ready: StoreReady, store: Store, command: StoreCommand, limits: Limits) StoreError!Outcome {
    var base = try environment(arena);
    return runStoreWith(arena, ready, store, command, limits, &base, capture_path);
}

fn runStoreWith(
    arena: Allocator,
    ready: StoreReady,
    store: Store,
    command: StoreCommand,
    limits: Limits,
    base: *std.process.Environ.Map,
    route_path: []const u8,
) StoreError!Outcome {
    for ([_][]const u8{ store.git_dir, store.index_file, store.work_tree, store.scratch_dir }) |dir| {
        if (!std.Io.Dir.path.isAbsolute(dir)) return error.InvalidArgument;
    }
    var argv: std.ArrayList([]const u8) = .empty;
    try appendStorePrelude(arena, &argv, ready, store.conversions);
    var input: std.ArrayList(u8) = .empty;
    var has_input = false;
    var reads_paths = false;
    switch (command) {
        .read_tree => |tree| {
            try argv.append(arena, "read-tree");
            if (tree) |oid| {
                try validateOid(oid);
                try argv.append(arena, oid);
            } else try argv.append(arena, "--empty");
        },
        .add_remove, .force_remove, .clear_flag => {
            const paths = switch (command) {
                .add_remove, .force_remove => |value| value,
                .clear_flag => |value| value.paths,
                else => unreachable,
            };
            try argv.appendSlice(arena, switch (command) {
                .add_remove => &.{ "update-index", "--add", "--remove", "-z", "--stdin" },
                .force_remove => &.{ "update-index", "--force-remove", "-z", "--stdin" },
                .clear_flag => |value| switch (value.flag) {
                    .assume_unchanged => &.{ "update-index", "--no-assume-unchanged", "-z", "--stdin" },
                    .skip_worktree => &.{ "update-index", "--no-skip-worktree", "-z", "--stdin" },
                },
                else => unreachable,
            });
            for (paths) |path| {
                if (!repo_path.isValid(path)) return error.InvalidArgument;
                try input.appendSlice(arena, path);
                try input.append(arena, 0);
            }
            has_input = true;
            reads_paths = true;
        },
        .index_info => |entries| {
            try argv.appendSlice(arena, &.{ "update-index", "-z", "--index-info" });
            for (entries) |entry| {
                try validateOid(entry.oid);
                if (!repo_path.isValid(entry.path)) return error.InvalidArgument;
                try input.print(arena, "{s} {s}\t{s}\x00", .{ entry.mode.text(), entry.oid, entry.path });
            }
            has_input = true;
            reads_paths = true;
        },
        .write_tree => try argv.append(arena, "write-tree"),
        .commit_tree => |commit| {
            try validateOid(commit.tree);
            if (commit.message.len == 0 or std.mem.findScalar(u8, commit.message, 0) != null) return error.InvalidArgument;
            try argv.appendSlice(arena, &.{ "commit-tree", commit.tree });
            if (commit.parent) |parent| {
                try validateOid(parent);
                try argv.appendSlice(arena, &.{ "-p", parent });
            }
            // The `@` form: git rejects a bare small number as an ambiguous date.
            const date = try arena.print("@{d} +0000", .{commit.unix_seconds});
            try base.put("GIT_AUTHOR_DATE", date);
            try base.put("GIT_COMMITTER_DATE", date);
            try input.appendSlice(arena, commit.message);
            has_input = true;
        },
        .update_ref => |update| {
            try validateRef(update.ref);
            try validateOid(update.new);
            const old = update.old orelse zeroOid(update.new.len);
            try validateOid(old);
            if (old.len != update.new.len) return error.InvalidArgument;
            try argv.appendSlice(arena, &.{ "update-ref", "--no-deref", update.ref, update.new, old });
        },
        .list_index => try argv.appendSlice(arena, &.{ "ls-files", "-z", "--stage", "-v" }),
        .resolve_ref => |ref| {
            try validateRef(ref);
            // `for-each-ref` prints nothing for a missing ref and still exits 0.
            try argv.appendSlice(arena, &.{ "for-each-ref", "--format=%(objectname)", ref });
        },
        .list_refs => try argv.appendSlice(arena, &.{ "for-each-ref", "--format=%(refname) %(objectname) %(committerdate:unix)", capture_ref_prefix }),
        .delete_ref => |delete| {
            try validateRef(delete.ref);
            try validateOid(delete.old);
            try argv.appendSlice(arena, &.{ "update-ref", "--no-deref", "-d", delete.ref, delete.old });
        },
        .gc => try argv.appendSlice(arena, &.{ "gc", "--quiet", "--prune=now" }),
    }
    if (comptime builtin.target.os.tag != .windows) try base.put("PATH", route_path);
    try base.put("GIT_DIR", store.git_dir);
    try base.put("GIT_INDEX_FILE", store.index_file);
    try base.put("GIT_WORK_TREE", store.work_tree);
    try base.put("GIT_AUTHOR_NAME", capture_identity_name);
    try base.put("GIT_AUTHOR_EMAIL", capture_identity_email);
    try base.put("GIT_COMMITTER_NAME", capture_identity_name);
    try base.put("GIT_COMMITTER_EMAIL", capture_identity_email);
    const outcome = try runBoundedWithStderr(arena, argv.items, store.work_tree, base, if (has_input) input.items else null, store.scratch_dir, limits);
    // `update-index` reports a path it refuses (an HFS or NTFS spelling of
    // `.git`, for example) and still exits 0. A capture missing an admitted
    // path must not look complete.
    if (reads_paths and outcome.result == .ok and std.mem.find(u8, outcome.stderr, "Ignoring path") != null) {
        return .{ .failed = .path_rejected };
    }
    return outcome.result;
}

/// Lists the whole user's repository containing `cwd` with the same prelude
/// as the agent's read-only git, as the fallback when the native indexer
/// refuses a format. Paths are relative to the worktree root. `ready` must
/// come from `prepare` for this `cwd`.
pub fn listRepository(arena: Allocator, ready: Ready, cwd: []const u8, listing: Listing, limits: Limits) Allocator.Error!Outcome {
    var base = try environment(arena);
    return listRepositoryWith(arena, ready, cwd, listing, limits, &base);
}

fn listRepositoryWith(
    arena: Allocator,
    ready: Ready,
    cwd: []const u8,
    listing: Listing,
    limits: Limits,
    base: *std.process.Environ.Map,
) Allocator.Error!Outcome {
    var argv: std.ArrayList([]const u8) = .empty;
    try appendPrelude(arena, &argv, ready);
    try argv.appendSlice(arena, switch (listing) {
        .tracked => &.{ "ls-files", "-z", "--full-name", "--stage", "-v", "--", ":/" },
        .untracked => &.{ "ls-files", "-z", "--full-name", "--others", "--exclude-standard", "--", ":/" },
    });
    return runBounded(arena, argv.items, cwd, base, null, null, limits);
}

/// What a capture needs to know about the user's repository, read through
/// the agent's read-only prelude: git reads config as data and runs nothing.
pub const RepositoryFacts = struct {
    /// Absolute paths as git resolves them from the directory it ran in.
    work_tree: []const u8,
    git_dir: []const u8,
    common_dir: []const u8,
    /// HEAD's commit, or null in an unborn repository.
    head: ?[]const u8,
    object_format: ObjectFormat,
    sparse_index: bool,
    split_index: bool,
    /// The repository's own conversion settings, so the store records the
    /// same tree; null where the repository leaves the setting unset.
    conversions: Conversions,
    /// Path comparisons git makes without case, or on precomposed Unicode.
    ignore_case: bool = false,
    precompose_unicode: bool = false,
};

/// Reads `RepositoryFacts` for the repository at `cwd`, or null when git
/// fails. `ready` must come from `prepare` for this `cwd`.
pub fn repositoryFacts(arena: Allocator, ready: Ready, cwd: []const u8, limits: Limits) Allocator.Error!?RepositoryFacts {
    var base = try environment(arena);
    return repositoryFactsWith(arena, ready, cwd, limits, &base);
}

fn repositoryFactsWith(arena: Allocator, ready: Ready, cwd: []const u8, limits: Limits, base: *std.process.Environ.Map) Allocator.Error!?RepositoryFacts {
    // One line per option, in order. `--git-common-dir` may be relative to
    // `cwd`; the other two are absolute.
    var paths_argv: std.ArrayList([]const u8) = .empty;
    try appendCommand(arena, &paths_argv, ready, .rev_parse);
    try paths_argv.appendSlice(arena, &.{ "--show-object-format", "--show-toplevel", "--absolute-git-dir", "--git-common-dir" });
    const paths_output = switch (try runBounded(arena, paths_argv.items, cwd, base, null, null, limits)) {
        .ok => |stdout| stdout,
        .failed => return null,
    };
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, paths_output, "\n"), '\n');
    const format_output = lines.next() orelse return null;
    const work_tree = lines.next() orelse return null;
    const git_dir = lines.next() orelse return null;
    const common_raw = lines.next() orelse return null;
    if (lines.next() != null or !std.Io.Dir.path.isAbsolute(work_tree) or !std.Io.Dir.path.isAbsolute(git_dir)) return null;
    const common_dir = if (std.Io.Dir.path.isAbsolute(common_raw)) common_raw else try std.Io.Dir.path.resolve(arena, &.{ cwd, common_raw });
    const object_format: ObjectFormat = if (std.mem.eql(u8, format_output, "sha1"))
        .sha1
    else if (std.mem.eql(u8, format_output, "sha256"))
        .sha256
    else
        return null;

    // `--verify -q` exits 1 with no output in an unborn repository, but also
    // when HEAD names a broken ref or an object that is not a commit, so a
    // failure counts as unborn only after `headIsUnborn` confirms it.
    var head_argv: std.ArrayList([]const u8) = .empty;
    try appendCommand(arena, &head_argv, ready, .rev_parse);
    try head_argv.appendSlice(arena, &.{ "--verify", "-q", "HEAD^{commit}" });
    const head: ?[]const u8 = switch (try runBounded(arena, head_argv.items, cwd, base, null, null, limits)) {
        .ok => |stdout| std.mem.trimEnd(u8, stdout, "\n"),
        .failed => |failure| if (failure == .exited_nonzero and try headIsUnborn(arena, ready, cwd, limits, base)) null else return null,
    };
    if (head) |oid| validateOid(oid) catch return null;

    var config_argv: std.ArrayList([]const u8) = .empty;
    try appendPrelude(arena, &config_argv, ready);
    try config_argv.appendSlice(arena, &.{ "config", "-z", "--list" });
    const config = switch (try runBounded(arena, config_argv.items, cwd, base, null, null, limits)) {
        .ok => |stdout| stdout,
        .failed => return null,
    };
    var facts: RepositoryFacts = .{
        .work_tree = work_tree,
        .git_dir = git_dir,
        .common_dir = common_dir,
        .head = head,
        .object_format = object_format,
        .sparse_index = false,
        .split_index = false,
        .conversions = .{},
    };
    // Later values win, as in git. `--list` reports keys in lowercase.
    var entries = std.mem.splitScalar(u8, config, 0);
    while (entries.next()) |entry| {
        const newline = std.mem.findScalar(u8, entry, '\n');
        const key = if (newline) |at| entry[0..at] else entry;
        // A key with no `=` has no value line and means true.
        const value = if (newline) |at| entry[at + 1 ..] else "true";
        if (std.mem.eql(u8, key, "index.sparse")) {
            facts.sparse_index = configBool(value) orelse facts.sparse_index;
        } else if (std.mem.eql(u8, key, "core.splitindex")) {
            facts.split_index = configBool(value) orelse facts.split_index;
        } else if (std.mem.eql(u8, key, "core.ignorecase")) {
            facts.ignore_case = configBool(value) orelse facts.ignore_case;
        } else if (std.mem.eql(u8, key, "core.precomposeunicode")) {
            facts.precompose_unicode = configBool(value) orelse facts.precompose_unicode;
        } else if (std.mem.eql(u8, key, "core.filemode")) {
            facts.conversions.file_mode = configBool(value) orelse facts.conversions.file_mode;
        } else if (std.mem.eql(u8, key, "core.symlinks")) {
            facts.conversions.symlinks = configBool(value) orelse facts.conversions.symlinks;
        } else if (std.mem.eql(u8, key, "core.autocrlf")) {
            if (std.ascii.eqlIgnoreCase(value, "input")) {
                facts.conversions.autocrlf = .input;
            } else if (configBool(value)) |enabled| {
                facts.conversions.autocrlf = if (enabled) .true else .false;
            }
        } else if (std.mem.eql(u8, key, "core.eol")) {
            if (std.ascii.eqlIgnoreCase(value, "lf")) facts.conversions.eol = .lf else if (std.ascii.eqlIgnoreCase(value, "crlf")) facts.conversions.eol = .crlf else if (std.ascii.eqlIgnoreCase(value, "native")) facts.conversions.eol = .native;
        }
    }
    return facts;
}

/// Whether HEAD is a symbolic ref to a branch that does not exist yet, the
/// only state a capture records as unborn. A detached HEAD, a HEAD that names
/// something other than a branch, and a branch that exists but does not
/// resolve to a commit are all unreadable. `symbolic-ref` itself fails when
/// the branch file is corrupt, so the `rev-parse` below fails only for a
/// missing branch.
fn headIsUnborn(arena: Allocator, ready: Ready, cwd: []const u8, limits: Limits, base: *std.process.Environ.Map) Allocator.Error!bool {
    var symbolic_argv: std.ArrayList([]const u8) = .empty;
    try appendPrelude(arena, &symbolic_argv, ready);
    try symbolic_argv.appendSlice(arena, &.{ "symbolic-ref", "-q", "HEAD" });
    const ref = switch (try runBounded(arena, symbolic_argv.items, cwd, base, null, null, limits)) {
        .ok => |stdout| std.mem.trimEnd(u8, stdout, "\n"),
        .failed => return false,
    };
    // The ref starts with `refs/`, so git cannot read it as an option.
    if (!std.mem.startsWith(u8, ref, "refs/heads/") or ref.len == "refs/heads/".len) return false;
    if (std.mem.findAny(u8, ref, "\n\r\x00") != null) return false;
    var verify_argv: std.ArrayList([]const u8) = .empty;
    try appendCommand(arena, &verify_argv, ready, .rev_parse);
    try verify_argv.appendSlice(arena, &.{ "--verify", "-q", ref });
    return switch (try runBounded(arena, verify_argv.items, cwd, base, null, null, limits)) {
        .ok => false,
        .failed => |failure| failure == .exited_nonzero,
    };
}

/// git's boolean spellings; null for anything else.
fn configBool(value: []const u8) ?bool {
    for ([_][]const u8{ "true", "yes", "on", "1" }) |word| if (std.ascii.eqlIgnoreCase(value, word)) return true;
    for ([_][]const u8{ "false", "no", "off", "0", "" }) |word| if (std.ascii.eqlIgnoreCase(value, word)) return false;
    return null;
}

fn appendStorePrelude(arena: Allocator, argv: *std.ArrayList([]const u8), ready: StoreReady, conversions: Conversions) Allocator.Error!void {
    try argv.appendSlice(arena, &.{
        ready.executable,
        "--no-pager",
        "--no-optional-locks",
        "--no-replace-objects",
        "-c",
        "core.fsmonitor=false",
        "-c",
        "core.hooksPath=/dev/null",
        "-c",
        "core.logAllRefUpdates=false",
        "-c",
        "core.splitIndex=false",
        "-c",
        "core.untrackedCache=false",
        "-c",
        "index.sparse=false",
        "-c",
        "gc.auto=0",
        "-c",
        "maintenance.auto=false",
        "-c",
        "commit.gpgSign=false",
        "-c",
        "log.showSignature=false",
    });
    if (conversions.file_mode) |value| try argv.appendSlice(arena, &.{ "-c", if (value) "core.fileMode=true" else "core.fileMode=false" });
    if (conversions.symlinks) |value| try argv.appendSlice(arena, &.{ "-c", if (value) "core.symlinks=true" else "core.symlinks=false" });
    if (conversions.autocrlf) |value| try argv.appendSlice(arena, &.{ "-c", switch (value) {
        .true => "core.autocrlf=true",
        .false => "core.autocrlf=false",
        .input => "core.autocrlf=input",
    } });
    if (conversions.eol) |value| try argv.appendSlice(arena, &.{ "-c", switch (value) {
        .lf => "core.eol=lf",
        .crlf => "core.eol=crlf",
        .native => "core.eol=native",
    } });
}

/// Whether `text` is an object ID of `format`: lowercase hex of its length.
pub fn isOid(text: []const u8, format: ObjectFormat) bool {
    const len: usize = switch (format) {
        .sha1 => 40,
        .sha256 => 64,
    };
    if (text.len != len) return false;
    for (text) |ch| switch (ch) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

fn validateOid(oid: []const u8) error{InvalidArgument}!void {
    if (!isOid(oid, .sha1) and !isOid(oid, .sha256)) return error.InvalidArgument;
}

/// `refs/fx/sessions/<session>/<worktree>`, each segment
/// `[A-Za-z0-9_-]{1,128}`. Exactly two segments: a one-segment ref would block
/// every worktree ref of that session, which git stores below it.
fn validateRef(ref: []const u8) error{InvalidArgument}!void {
    if (!std.mem.startsWith(u8, ref, capture_ref_prefix)) return error.InvalidArgument;
    var segments = std.mem.splitScalar(u8, ref[capture_ref_prefix.len..], '/');
    var count: usize = 0;
    while (segments.next()) |name| : (count += 1) {
        if (count == 2 or name.len == 0 or name.len > 128) return error.InvalidArgument;
        for (name) |c| switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
            else => return error.InvalidArgument,
        };
    }
    if (count != 2) return error.InvalidArgument;
}

fn zeroOid(len: usize) []const u8 {
    const zeros = "0000000000000000000000000000000000000000000000000000000000000000";
    return zeros[0..len];
}

fn runBounded(
    arena: Allocator,
    argv: []const []const u8,
    cwd: []const u8,
    env: *const std.process.Environ.Map,
    input: ?[]const u8,
    scratch_dir: ?[]const u8,
    limits: Limits,
) Allocator.Error!Outcome {
    return (try runBoundedWithStderr(arena, argv, cwd, env, input, scratch_dir, limits)).result;
}

const BoundedRun = struct {
    result: Outcome,
    /// Buffered standard error, owned by the arena; empty on early failure.
    stderr: []const u8 = "",
};

/// Runs `argv` in its own process group with a deadline, bounded output and
/// optional input. On every early return the whole group gets SIGTERM, so a
/// slow filter git started dies with it and git removes its index lock.
fn runBoundedWithStderr(
    arena: Allocator,
    argv: []const []const u8,
    cwd: []const u8,
    env: *const std.process.Environ.Map,
    input: ?[]const u8,
    scratch_dir: ?[]const u8,
    limits: Limits,
) Allocator.Error!BoundedRun {
    const io = io_mod.getIo();
    // A capture that already spent its shared budget starts nothing.
    if (limits.deadline) |at| {
        if (at.compare(.lte, .now(io, at.clock))) return .{ .result = .{ .failed = .timeout } };
    }
    var input_file: ?std.Io.File = null;
    var input_path: ?[]const u8 = null;
    defer {
        if (input_file) |file| file.close(io);
        if (input_path) |path| std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    }
    if (input) |bytes| {
        const dir = scratch_dir orelse return .{ .result = .{ .failed = .input_failed } };
        const name = try arena.print("safe-git-input-{d}-{d}", .{ io_mod.nanoTimestamp(), input_counter.fetchAdd(1, .monotonic) });
        const path = try std.Io.Dir.path.join(arena, &.{ dir, name });
        writeInput(io, path, bytes) catch return .{ .result = .{ .failed = .input_failed } };
        input_path = path;
        input_file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return .{ .result = .{ .failed = .input_failed } };
        // Once open, the name is no longer needed; drop it so a crash leaves
        // no file naming the captured paths.
        if (comptime has_process_groups) {
            std.Io.Dir.deleteFileAbsolute(io, path) catch {};
            input_path = null;
        }
    }

    var options: std.process.SpawnOptions = .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .environ_map = env,
        .stdin = if (input_file) |file| .{ .file = file } else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    };
    if (comptime has_process_groups) options.pgid = 0;
    var child = std.process.spawn(io, options) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .result = .{ .failed = .spawn_failed } },
    };
    var finished = false;
    defer {
        if (!finished) terminateGroup(&child);
        child.kill(io);
    }

    var buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var reader: std.Io.File.MultiReader = undefined;
    reader.init(arena, io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer reader.deinit();
    const deadline: std.Io.Timeout = if (limits.deadline) |at|
        .{ .deadline = at }
    else
        .{ .deadline = .fromNow(io, .{ .clock = .awake, .raw = .fromMilliseconds(limits.timeout_ms) }) };
    while (reader.fill(64, deadline)) |_| {
        if (reader.reader(0).buffered().len > limits.max_stdout) return .{ .result = .{ .failed = .output_too_large } };
        if (reader.reader(1).buffered().len > max_capture_stderr) return .{ .result = .{ .failed = .output_too_large } };
    } else |err| switch (err) {
        error.EndOfStream => {},
        error.Timeout => return .{ .result = .{ .failed = .timeout } },
        error.Canceled => {
            io.recancel();
            return .{ .result = .{ .failed = .cancelled } };
        },
        else => return .{ .result = .{ .failed = .read_failed } },
    }
    reader.checkAnyError() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => {
            io.recancel();
            return .{ .result = .{ .failed = .cancelled } };
        },
        else => return .{ .result = .{ .failed = .read_failed } },
    };
    const term = child.wait(io) catch |err| switch (err) {
        error.Canceled => {
            io.recancel();
            return .{ .result = .{ .failed = .cancelled } };
        },
        else => return .{ .result = .{ .failed = .read_failed } },
    };
    finished = true;
    const stdout = try reader.toOwnedSlice(0);
    const stderr = try reader.toOwnedSlice(1);
    switch (term) {
        .exited => |code| if (code == 0) return .{ .result = .{ .ok = stdout }, .stderr = stderr },
        else => {},
    }
    debug_trace.logf("core", "capture git failed command={s} term={t} stderr={s}", .{
        if (argv.len > 0) argv[argv.len - 1] else "",
        term,
        stderr[0..@min(stderr.len, 512)],
    });
    return .{ .result = .{ .failed = if (term == .exited) .exited_nonzero else .terminated }, .stderr = stderr };
}

fn writeInput(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var file = try std.Io.Dir.createFileAbsolute(io, path, .{ .exclusive = true, .permissions = .fromMode(0o600) });
    defer file.close(io);
    errdefer std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    try file.writeStreamingAll(io, bytes);
}

/// Sends SIGTERM to the child's process group, which includes any filter git
/// started, then SIGCONT: the group runs in the background of fx's terminal,
/// so a member stopped by reading it would otherwise never act on SIGTERM and
/// `child.kill` would wait for it forever.
fn terminateGroup(child: *std.process.Child) void {
    // A block, not an early return: the signal names do not exist on hosts
    // without process groups, such as WASI, and Zig checks code after a
    // comptime return.
    if (comptime has_process_groups) {
        const pid = child.id orelse return;
        for ([_]std.posix.SIG{ .TERM, .CONT }) |signal| {
            std.posix.kill(-pid, signal) catch |err| switch (err) {
                error.ProcessNotFound => return,
                else => debug_trace.logf("core", "capture git group signal failed sig={t} err={s}", .{ signal, @errorName(err) }),
            };
        }
    }
}

test "git version check requires 2.25 and reads vendor suffixes" {
    const cases = [_]struct { output: []const u8, expected: VersionCheck }{
        .{ .output = "git version 2.50.1 (Apple Git-155)\n", .expected = .supported },
        .{ .output = "git version 2.36.0\n", .expected = .supported },
        .{ .output = "git version 2.34.1\n", .expected = .supported },
        .{ .output = "git version 2.25.0\n", .expected = .supported },
        .{ .output = "git version 2.39.3.windows.1\n", .expected = .supported },
        .{ .output = "git version 3.0.0\n", .expected = .supported },
        .{ .output = "git version 2.24.4\n", .expected = .too_old },
        .{ .output = "git version 1.9.5\n", .expected = .too_old },
        .{ .output = "hub version 2.14\n", .expected = .unknown },
        .{ .output = "git version x.y\n", .expected = .unknown },
    };
    for (cases) |case| try std.testing.expectEqual(case.expected, classifyVersion(case.output));
    // The capture route needs 2.29.
    try std.testing.expectEqual(VersionCheck.too_old, classifyVersionAtLeast("git version 2.28.0\n", store_minimum_minor));
    try std.testing.expectEqual(VersionCheck.supported, classifyVersionAtLeast("git version 2.29.0\n", store_minimum_minor));
}

test "safe git argv turns off repository programs for every subcommand" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ready: Ready = .{ .executable = "/usr/bin/git", .filter_names = &.{ "lfs", "evil.x" } };
    var argv: std.ArrayList([]const u8) = .empty;
    try appendCommand(arena, &argv, ready, .diff);
    const expected = [_][]const u8{
        "/usr/bin/git",             "--no-pager",           "--no-optional-locks",
        "-c",                       "core.fsmonitor=false", "-c",
        "core.hooksPath=/dev/null", "-c",                   "log.showSignature=false",
        "-c",                       "filter.lfs.clean=",    "-c",
        "filter.lfs.smudge=",       "-c",                   "filter.lfs.process=",
        "-c",                       "filter.evil.x.clean=", "-c",
        "filter.evil.x.smudge=",    "-c",                   "filter.evil.x.process=",
        "diff",                     "--no-ext-diff",        "--no-textconv",
        "--ignore-submodules=all",
    };
    try std.testing.expectEqual(expected.len, argv.items.len);
    for (expected, argv.items) |want, have| try std.testing.expectEqualStrings(want, have);
}

test "safe git environment keeps only fixed values and user config locations" {
    var env = try environment(std.testing.allocator);
    defer env.deinit();
    try std.testing.expectEqualStrings("/usr/bin:/bin", env.get("PATH").?);
    try std.testing.expectEqualStrings("0", env.get("GIT_OPTIONAL_LOCKS").?);
    try std.testing.expectEqualStrings("0", env.get("GIT_TERMINAL_PROMPT").?);
    try std.testing.expectEqualStrings("cat", env.get("GIT_PAGER").?);
    for ([_][]const u8{ "GIT_DIR", "GIT_WORK_TREE", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT", "GIT_EXEC_PATH" }) |key| {
        try std.testing.expect(env.get(key) == null);
    }
}

/// A real repository with a sentinel program that appends to a log whenever
/// git runs it. Setup and control runs use plain git; helper runs use the
/// helper's environment. Both are isolated from the developer's git config.
/// There is no pager route here: git never pages when its output is not a
/// terminal, and fx always pipes it, so `--no-pager` and `GIT_PAGER=cat` are
/// covered by the argv and environment tests above.
const SentinelRepo = struct {
    arena: Allocator,
    git: []const u8,
    root: []const u8,
    repo: []const u8,
    home: []const u8,
    log: []const u8,
    sentinel: []const u8,

    const Mode = union(enum) {
        plain,
        /// The helper's environment, optionally reading this system config.
        safe: ?[]const u8,
    };

    fn init(arena: Allocator, dir: std.Io.Dir) !SentinelRepo {
        const git = trustedExecutable() orelse return error.SkipZigTest;
        if (try versionCheckAtLeast(arena, git, minimum_minor, null) != .supported) return error.SkipZigTest;
        const root = try io_mod.dirRealpathAlloc(arena, dir, ".");
        const self: SentinelRepo = .{
            .arena = arena,
            .git = git,
            .root = root,
            .repo = try std.Io.Dir.path.join(arena, &.{ root, "repo" }),
            .home = try std.Io.Dir.path.join(arena, &.{ root, "home" }),
            .log = try std.Io.Dir.path.join(arena, &.{ root, "sentinel.log" }),
            .sentinel = try std.Io.Dir.path.join(arena, &.{ root, "sentinel.sh" }),
        };
        try dir.createDirPath(std.testing.io, "home");
        try dir.createDirPath(std.testing.io, "repo");
        try self.writeExecutable(self.sentinel);
        try self.plain(self.repo, &.{ "init", "-q", "--template=", "-b", "main" });
        try self.write("repo/a.txt", "one\n");
        try self.plain(self.repo, &.{ "add", "a.txt" });
        try self.commit(self.repo);
        return self;
    }

    fn path(self: SentinelRepo, sub_path: []const u8) ![]const u8 {
        return std.Io.Dir.path.join(self.arena, &.{ self.root, sub_path });
    }

    fn writeExecutable(self: SentinelRepo, absolute: []const u8) !void {
        const script = try self.arena.print("#!/bin/sh\necho ran >> '{s}'\ncat\n", .{self.log});
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = absolute, .data = script, .flags = .{ .permissions = .fromMode(0o755) } });
    }

    fn write(self: SentinelRepo, sub_path: []const u8, data: []const u8) !void {
        const absolute = try self.path(sub_path);
        if (std.Io.Dir.path.dirname(absolute)) |parent| try std.Io.Dir.cwd().createDirPath(std.testing.io, parent);
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = absolute, .data = data });
    }

    fn commit(self: SentinelRepo, cwd: []const u8) !void {
        try self.plain(cwd, &.{ "-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid", "commit", "-q", "-m", "fixture" });
    }

    fn childEnvironment(self: SentinelRepo, mode: Mode) !std.process.Environ.Map {
        var env = switch (mode) {
            .plain => blk: {
                var plain_env = std.process.Environ.Map.init(self.arena);
                try plain_env.put("PATH", "/usr/bin:/bin");
                try plain_env.put("LC_ALL", "C");
                break :blk plain_env;
            },
            .safe => try environment(self.arena),
        };
        try env.put("HOME", self.home);
        try env.put("XDG_CONFIG_HOME", try std.Io.Dir.path.join(self.arena, &.{ self.home, ".config" }));
        try env.put("GIT_CONFIG_GLOBAL", try std.Io.Dir.path.join(self.arena, &.{ self.home, ".gitconfig" }));
        const system: ?[]const u8 = switch (mode) {
            .plain => null,
            .safe => |value| value,
        };
        if (system) |config_path| {
            try env.put("GIT_CONFIG_SYSTEM", config_path);
            try env.put("GIT_CONFIG_NOSYSTEM", "0");
        } else try env.put("GIT_CONFIG_NOSYSTEM", "1");
        return env;
    }

    fn run(self: SentinelRepo, cwd: []const u8, argv: []const []const u8, mode: Mode) !std.process.RunResult {
        var env = try self.childEnvironment(mode);
        return std.process.run(self.arena, std.testing.io, .{
            .argv = argv,
            .cwd = .{ .path = cwd },
            .environ_map = &env,
            .stdout_limit = .limited(1 << 20),
            .stderr_limit = .limited(1 << 20),
        });
    }

    fn plainArgv(self: SentinelRepo, args: []const []const u8) ![]const []const u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(self.arena, self.git);
        try argv.appendSlice(self.arena, args);
        return argv.items;
    }

    fn plainOutput(self: SentinelRepo, cwd: []const u8, args: []const []const u8) ![]const u8 {
        const result = try self.run(cwd, try self.plainArgv(args), .plain);
        switch (result.term) {
            .exited => |code| if (code == 0) return std.mem.trimEnd(u8, result.stdout, "\n"),
            else => {},
        }
        std.debug.print("fixture git {s} failed: {s}\n", .{ args[0], result.stderr });
        return error.FixtureGitFailed;
    }

    fn plain(self: SentinelRepo, cwd: []const u8, args: []const []const u8) !void {
        _ = try self.plainOutput(cwd, args);
    }

    fn runs(self: SentinelRepo) !usize {
        var file = std.Io.Dir.openFileAbsolute(std.testing.io, self.log, .{}) catch |err| switch (err) {
            error.FileNotFound => return 0,
            else => return err,
        };
        const data = try io_mod.readFileToEnd(self.arena, &file, 1 << 16);
        file.close(std.testing.io);
        try std.Io.Dir.deleteFileAbsolute(std.testing.io, self.log);
        return std.mem.count(u8, data, "ran\n");
    }

    fn ready(self: SentinelRepo, cwd: []const u8) !Ready {
        return switch (try prepare(self.arena, cwd)) {
            .ready => |value| value,
            .refused => |reason| {
                std.debug.print("safe git refused: {s}\n", .{@tagName(reason)});
                return error.TestUnexpectedRefusal;
            },
        };
    }

    fn helperArgv(self: SentinelRepo, cwd: []const u8, subcommand: Subcommand, args: []const []const u8) ![]const []const u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        try appendCommand(self.arena, &argv, try self.ready(cwd), subcommand);
        try argv.appendSlice(self.arena, args);
        return argv.items;
    }

    /// Runs `subcommand` through the helper, then `control` through plain
    /// git. The helper must never run the sentinel; the control must, or the
    /// fixture does not exercise the route. The helper runs first because it
    /// never refreshes the index, which would hide the change from the control.
    fn expectBlocked(self: SentinelRepo, cwd: []const u8, subcommand: Subcommand, args: []const []const u8, control: []const []const u8) !void {
        _ = try self.run(cwd, try self.helperArgv(cwd, subcommand, args), .{ .safe = null });
        try std.testing.expectEqual(@as(usize, 0), try self.runs());
        _ = try self.run(cwd, try self.plainArgv(control), .plain);
        try std.testing.expect(try self.runs() > 0);
    }
};

test "safe git blocks a repository fsmonitor" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try SentinelRepo.init(arena_state.allocator(), tmp.dir);
    try repo.plain(repo.repo, &.{ "config", "core.fsmonitor", repo.sentinel });
    try repo.write("repo/a.txt", "one\n");
    try repo.expectBlocked(repo.repo, .status, &.{"--short"}, &.{ "status", "--short" });
}

test "safe git blocks repository hooks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try SentinelRepo.init(arena_state.allocator(), tmp.dir);
    const hooks = try repo.path("hooks");
    try std.Io.Dir.cwd().createDirPath(std.testing.io, hooks);
    try repo.writeExecutable(try repo.path("hooks/post-index-change"));
    try repo.plain(repo.repo, &.{ "config", "core.hooksPath", hooks });
    try repo.write("repo/a.txt", "one\n");
    try repo.expectBlocked(repo.repo, .status, &.{"--short"}, &.{ "status", "--short" });
}

test "safe git blocks a repository external diff and textconv" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try SentinelRepo.init(arena_state.allocator(), tmp.dir);
    try repo.plain(repo.repo, &.{ "config", "diff.external", repo.sentinel });
    try repo.write("repo/a.txt", "two\n");
    try repo.expectBlocked(repo.repo, .diff, &.{"--stat"}, &.{"diff"});

    try repo.plain(repo.repo, &.{ "config", "--unset", "diff.external" });
    try repo.write("repo/.git/info/attributes", "a.txt diff=tc\n");
    try repo.plain(repo.repo, &.{ "config", "diff.tc.textconv", repo.sentinel });
    try repo.expectBlocked(repo.repo, .diff, &.{"--stat"}, &.{"diff"});
}

test "safe git blocks repository clean, process and smudge filters" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try SentinelRepo.init(arena_state.allocator(), tmp.dir);
    try repo.write("repo/.git/info/attributes", "a.txt filter=evil\n");

    try repo.plain(repo.repo, &.{ "config", "filter.evil.clean", repo.sentinel });
    try repo.write("repo/a.txt", "two\n");
    try repo.expectBlocked(repo.repo, .status, &.{"--short"}, &.{ "status", "--short" });
    try repo.write("repo/a.txt", "three\n");
    try repo.expectBlocked(repo.repo, .diff, &.{"--stat"}, &.{ "diff", "--stat" });
    try repo.plain(repo.repo, &.{ "config", "--unset", "filter.evil.clean" });

    try repo.plain(repo.repo, &.{ "config", "filter.evil.process", repo.sentinel });
    // Same size as the committed "one\n": with a different size, git status
    // can report the change from the index stat alone and skip the filter.
    try repo.write("repo/a.txt", "ten\n");
    try repo.expectBlocked(repo.repo, .status, &.{"--short"}, &.{ "status", "--short" });
    try repo.plain(repo.repo, &.{ "config", "--unset", "filter.evil.process" });

    // No read-only command checks files out, so smudge is shown through the
    // shared prelude on `checkout`, where git would run it.
    try repo.plain(repo.repo, &.{ "config", "filter.evil.smudge", repo.sentinel });
    const file = try repo.path("repo/a.txt");
    var argv: std.ArrayList([]const u8) = .empty;
    try appendPrelude(repo.arena, &argv, try repo.ready(repo.repo));
    try argv.appendSlice(repo.arena, &.{ "checkout", "--", "a.txt" });
    try std.Io.Dir.deleteFileAbsolute(std.testing.io, file);
    _ = try repo.run(repo.repo, argv.items, .{ .safe = null });
    try std.testing.expectEqual(@as(usize, 0), try repo.runs());
    try std.Io.Dir.deleteFileAbsolute(std.testing.io, file);
    _ = try repo.run(repo.repo, try repo.plainArgv(&.{ "checkout", "--", "a.txt" }), .plain);
    try std.testing.expect(try repo.runs() > 0);
}

test "safe git blocks a repository signature program" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try SentinelRepo.init(arena_state.allocator(), tmp.dir);
    const object = try repo.arena.print(
        \\tree {s}
        \\parent {s}
        \\author fixture <fixture@example.invalid> 1 +0000
        \\committer fixture <fixture@example.invalid> 1 +0000
        \\gpgsig -----BEGIN PGP SIGNATURE-----
        \\ 
        \\ AAAA
        \\ -----END PGP SIGNATURE-----
        \\
        \\signed
        \\
    , .{ try repo.plainOutput(repo.repo, &.{ "rev-parse", "HEAD^{tree}" }), try repo.plainOutput(repo.repo, &.{ "rev-parse", "HEAD" }) });
    const object_path = try repo.path("signed-commit");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = object_path, .data = object });
    const signed = try repo.plainOutput(repo.repo, &.{ "hash-object", "-t", "commit", "-w", object_path });
    try repo.plain(repo.repo, &.{ "update-ref", "refs/heads/main", signed });
    try repo.plain(repo.repo, &.{ "config", "log.showSignature", "true" });
    try repo.plain(repo.repo, &.{ "config", "gpg.program", repo.sentinel });
    try repo.expectBlocked(repo.repo, .log, &.{ "--oneline", "-1" }, &.{ "log", "-1" });
}

test "safe git does not enter submodules, whose config it never read" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try SentinelRepo.init(arena_state.allocator(), tmp.dir);
    const sub = try repo.path("repo/sub");
    try std.Io.Dir.cwd().createDirPath(std.testing.io, sub);
    try repo.plain(sub, &.{ "init", "-q", "--template=", "-b", "main" });
    try repo.write("repo/sub/b.txt", "one\n");
    try repo.plain(sub, &.{ "add", "b.txt" });
    try repo.commit(sub);
    try repo.plain(repo.repo, &.{ "add", "sub" });
    try repo.commit(repo.repo);
    try repo.write("repo/sub/.git/info/attributes", "b.txt filter=evil\n");
    try repo.plain(sub, &.{ "config", "filter.evil.clean", repo.sentinel });
    try repo.write("repo/sub/b.txt", "two\n");
    try repo.expectBlocked(repo.repo, .status, &.{"--short"}, &.{ "status", "--short" });
}

test "safe git keeps trusted system config filters" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try SentinelRepo.init(arena_state.allocator(), tmp.dir);
    const system = try repo.path("system.gitconfig");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = system,
        .data = try repo.arena.print("[filter \"trusted\"]\n\tclean = {s}\n", .{repo.sentinel}),
    });
    try repo.write("repo/.git/info/attributes", "a.txt filter=trusted\n");
    try repo.write("repo/a.txt", "two\n");
    _ = try repo.run(repo.repo, try repo.helperArgv(repo.repo, .status, &.{"--short"}), .{ .safe = system });
    try std.testing.expect(try repo.runs() > 0);
}

test "safe git follows git's repository choice and refuses what it cannot blank" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try SentinelRepo.init(arena_state.allocator(), tmp.dir);

    // git skips an inner `.git` without `refs` and uses the outer repository.
    // fx makes the same choice, so the outer repository's filter is blanked.
    try repo.write("repo/.git/info/attributes", "a.txt filter=evil\n");
    try repo.plain(repo.repo, &.{ "config", "filter.evil.clean", repo.sentinel });
    try repo.write("repo/inner/.git/HEAD", "ref: refs/heads/main\n");
    try std.Io.Dir.cwd().createDirPath(std.testing.io, try repo.path("repo/inner/.git/objects"));
    const inner = try repo.path("repo/inner");
    try repo.write("repo/a.txt", "two\n");
    try repo.expectBlocked(inner, .status, &.{"--short"}, &.{ "status", "--short" });

    // A git directory used as the workspace, with a separate work tree. git
    // uses it; fx's discovery does not, so safe git refuses.
    const gitdir = try repo.path("gitdir");
    try repo.plain(repo.root, &.{ "init", "-q", "--bare", "--template=", gitdir });
    try repo.plain(gitdir, &.{ "config", "core.bare", "false" });
    try repo.plain(gitdir, &.{ "config", "core.worktree", repo.repo });
    try std.testing.expectEqual(Refusal.repository_mismatch, (try prepare(repo.arena, gitdir)).refused);

    // An inner repository whose `HEAD` is a symlink into `refs/`. git uses
    // it; fx's discovery rejects it and reads the outer repository, so the two
    // disagree and safe git refuses instead of running with the wrong config.
    const linked = try repo.path("repo/linked");
    try repo.plain(repo.repo, &.{ "init", "-q", "--template=", linked });
    const linked_head = try repo.path("repo/linked/.git/HEAD");
    try std.Io.Dir.cwd().deleteFile(std.testing.io, linked_head);
    try std.Io.Dir.cwd().symLink(std.testing.io, "refs/heads/main", linked_head, .{ .is_directory = false });
    try std.testing.expectEqual(Refusal.repository_mismatch, (try prepare(repo.arena, linked)).refused);

    try repo.plain(repo.repo, &.{ "config", "filter.a=b.clean", repo.sentinel });
    try std.testing.expectEqual(Refusal.unsupported_filter_name, (try prepare(repo.arena, repo.repo)).refused);
}

/// A capture store beside a `SentinelRepo`, with alternates into its objects.
const StoreFixture = struct {
    /// The capture route's PATH; a test may put a fixture folder first.
    path: []const u8 = capture_path,
    repo: SentinelRepo,
    ready: StoreReady,
    store: Store,

    fn init(repo: SentinelRepo) !StoreFixture {
        return initFormat(repo, .sha1, "repo");
    }

    fn initFormat(repo: SentinelRepo, format: ObjectFormat, work_tree: []const u8) !StoreFixture {
        const ready = switch (try prepareStore(repo.arena, .{})) {
            .ready => |value| value,
            .refused => return error.SkipZigTest,
        };
        const store: Store = .{
            .git_dir = try repo.path("store.git"),
            .index_file = try repo.path("capture-index"),
            .work_tree = try repo.path(work_tree),
            .scratch_dir = try repo.path("scratch"),
        };
        try std.Io.Dir.cwd().createDirPath(std.testing.io, store.scratch_dir);
        var env = try repo.childEnvironment(.{ .safe = null });
        _ = try expectOk(try initStoreWith(repo.arena, ready, store.git_dir, format, .{}, &env));
        try repo.write("store.git/objects/info/alternates", try repo.arena.print("{s}\n", .{try repo.path(try repo.arena.print("{s}/.git/objects", .{work_tree}))}));
        return .{ .repo = repo, .ready = ready, .store = store };
    }

    fn run(self: StoreFixture, command: StoreCommand, mode: SentinelRepo.Mode, limits: Limits) !Outcome {
        var env = try self.repo.childEnvironment(mode);
        return runStoreWith(self.repo.arena, self.ready, self.store, command, limits, &env, self.path);
    }

    fn ok(self: StoreFixture, command: StoreCommand) ![]const u8 {
        return expectOk(try self.run(command, .{ .safe = null }, .{}));
    }

    fn storeOutput(self: StoreFixture, args: []const []const u8) ![]const u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(self.repo.arena, &.{ "--git-dir", self.store.git_dir });
        try argv.appendSlice(self.repo.arena, args);
        return self.repo.plainOutput(self.repo.root, argv.items);
    }
};

fn expectOk(outcome: Outcome) ![]const u8 {
    return switch (outcome) {
        .ok => |stdout| std.mem.trimEnd(u8, stdout, "\n"),
        .failed => |failure| {
            std.debug.print("capture git failed: {s}\n", .{@tagName(failure)});
            return error.TestUnexpectedFailure;
        },
    };
}

fn expectFailure(expected: Failure, outcome: Outcome) !void {
    switch (outcome) {
        .ok => return error.TestExpectedFailure,
        .failed => |failure| try std.testing.expectEqual(expected, failure),
    }
}

fn readFixtureFile(repo: SentinelRepo, sub_path: []const u8) ![]const u8 {
    var file = try std.Io.Dir.openFileAbsolute(std.testing.io, try repo.path(sub_path), .{});
    defer file.close(std.testing.io);
    return io_mod.readFileToEnd(repo.arena, &file, 1 << 24);
}

test "safe git store argv turns off programs, reflogs, signing and index extensions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var argv: std.ArrayList([]const u8) = .empty;
    try appendStorePrelude(arena, &argv, .{ .executable = "/usr/bin/git" }, .{ .file_mode = false, .autocrlf = .input });
    try std.testing.expectEqualStrings("/usr/bin/git", argv.items[0]);
    for ([_][]const u8{
        "core.fsmonitor=false",
        "core.hooksPath=/dev/null",
        "core.logAllRefUpdates=false",
        "core.splitIndex=false",
        "core.untrackedCache=false",
        "index.sparse=false",
        "gc.auto=0",
        "maintenance.auto=false",
        "commit.gpgSign=false",
        "core.fileMode=false",
        "core.autocrlf=input",
    }) |setting| {
        const at = for (argv.items, 0..) |arg, i| {
            if (std.mem.eql(u8, arg, setting)) break i;
        } else {
            std.debug.print("missing {s}\n", .{setting});
            return error.TestMissingSetting;
        };
        try std.testing.expectEqualStrings("-c", argv.items[at - 1]);
    }
}

test "safe git store rejects malformed objects, refs, paths and relative stores" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ready: StoreReady = .{ .executable = "/usr/bin/git" };
    const store: Store = .{ .git_dir = "/x/store.git", .index_file = "/x/index", .work_tree = "/x/repo", .scratch_dir = "/x/scratch" };
    const oid = "0123456789abcdef0123456789abcdef01234567";
    const invalid = [_]StoreCommand{
        .{ .read_tree = "0123456789ABCDEF0123456789ABCDEF01234567" },
        .{ .read_tree = "0123" },
        .{ .add_remove = &.{"/etc/passwd"} },
        .{ .add_remove = &.{""} },
        .{ .add_remove = &.{"a//b"} },
        .{ .add_remove = &.{"./a"} },
        .{ .add_remove = &.{"a/../../b"} },
        .{ .add_remove = &.{".git/config"} },
        .{ .index_info = &.{.{ .mode = .file, .oid = oid, .path = "a/.GIT/x" }} },
        .{ .clear_flag = .{ .flag = .skip_worktree, .paths = &.{"a\x00b"} } },
        .{ .index_info = &.{.{ .mode = .file, .oid = "nothex", .path = "a" }} },
        .{ .commit_tree = .{ .tree = oid, .parent = null, .message = "", .unix_seconds = 1 } },
        .{ .commit_tree = .{ .tree = oid, .parent = "bad", .message = "m", .unix_seconds = 1 } },
        .{ .update_ref = .{ .ref = "refs/heads/main", .new = oid, .old = null } },
        .{ .update_ref = .{ .ref = "refs/fx/sessions/a.lock/w", .new = oid, .old = null } },
        .{ .update_ref = .{ .ref = "refs/fx/sessions/one-segment", .new = oid, .old = null } },
        .{ .update_ref = .{ .ref = "refs/fx/sessions/../../heads/main", .new = oid, .old = null } },
        .{ .update_ref = .{ .ref = "refs/fx/sessions/", .new = oid, .old = null } },
        .{ .update_ref = .{ .ref = "refs/fx/sessions/a/b/c", .new = oid, .old = null } },
        .{ .update_ref = .{ .ref = "refs/fx/sessions/a//b", .new = oid, .old = null } },
        .{ .update_ref = .{ .ref = "refs/fx/sessions/a/", .new = oid, .old = null } },
        .{ .update_ref = .{ .ref = "refs/fx/sessions/s/w", .new = oid, .old = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" } },
    };
    for (invalid) |command| {
        var env = try environment(arena);
        try std.testing.expectError(error.InvalidArgument, runStoreWith(arena, ready, store, command, .{}, &env, capture_path));
    }
    var relative = store;
    relative.git_dir = "store.git";
    var env = try environment(arena);
    try std.testing.expectError(error.InvalidArgument, runStoreWith(arena, ready, relative, .write_tree, .{}, &env, capture_path));
    try std.testing.expectError(error.InvalidArgument, initStoreWith(arena, ready, "store.git", .sha1, .{}, &env));
}

test "safe git capture store records the worktree without running repository programs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try SentinelRepo.init(arena_state.allocator(), tmp.dir);
    const hooks = try repo.path("hooks");
    try std.Io.Dir.cwd().createDirPath(std.testing.io, hooks);
    try repo.writeExecutable(try repo.path("hooks/post-index-change"));
    try repo.plain(repo.repo, &.{ "config", "core.hooksPath", hooks });
    try repo.plain(repo.repo, &.{ "config", "core.fsmonitor", repo.sentinel });
    try repo.plain(repo.repo, &.{ "config", "filter.evil.clean", repo.sentinel });
    try repo.plain(repo.repo, &.{ "config", "filter.evil.process", repo.sentinel });
    try repo.write("repo/.git/info/attributes", "* filter=evil\n");
    try repo.write("repo/.gitattributes", "a.txt filter=evil\n");
    // Same size as the committed "one\n", so only content can show the change.
    try repo.write("repo/a.txt", "ten\n");
    try repo.write("repo/sp ace", "space\n");
    try repo.write("repo/new\nline", "newline\n");
    const head = try repo.plainOutput(repo.repo, &.{ "rev-parse", "HEAD" });
    const user_index = try readFixtureFile(repo, "repo/.git/index");

    const fixture = try StoreFixture.init(repo);
    _ = try repo.runs();
    _ = try fixture.ok(.{ .read_tree = head });
    _ = try fixture.ok(.{ .add_remove = &.{ "a.txt", ".gitattributes", "sp ace", "new\nline" } });
    const tree = try fixture.ok(.write_tree);
    const commit = try fixture.ok(.{ .commit_tree = .{ .tree = tree, .parent = null, .message = "capture\n", .unix_seconds = 1 } });
    _ = try fixture.ok(.{ .update_ref = .{ .ref = "refs/fx/sessions/s1/w", .new = commit, .old = null } });

    try std.testing.expectEqual(@as(usize, 0), try repo.runs());
    try std.testing.expectEqualSlices(u8, user_index, try readFixtureFile(repo, "repo/.git/index"));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.openFileAbsolute(std.testing.io, try repo.path("scratch/safe-git-input"), .{}));

    // The user's own git, with the planted programs blanked, records the same tree.
    const blank = [_][]const u8{ "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "filter.evil.clean=", "-c", "filter.evil.process=" };
    try repo.plain(repo.repo, &(blank ++ [_][]const u8{ "add", "-A" }));
    try std.testing.expectEqualStrings(try repo.plainOutput(repo.repo, &(blank ++ [_][]const u8{"write-tree"})), tree);

    // Control: plain git in the same repository runs the planted programs.
    try repo.write("repo/a.txt", "six\n");
    _ = try repo.run(repo.repo, try repo.plainArgv(&.{ "status", "--short" }), .plain);
    try std.testing.expect(try repo.runs() > 0);
}

test "safe git capture store ignores hostile global identity, reflog, hook, fsmonitor and signing settings" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try SentinelRepo.init(arena_state.allocator(), tmp.dir);
    const head = try repo.plainOutput(repo.repo, &.{ "rev-parse", "HEAD" });
    const fixture = try StoreFixture.init(repo);
    const hooks = try repo.path("global-hooks");
    try std.Io.Dir.cwd().createDirPath(std.testing.io, hooks);
    try repo.writeExecutable(try repo.path("global-hooks/post-index-change"));
    try repo.write("home/.gitconfig", try repo.arena.print(
        "[core]\n\tlogAllRefUpdates = always\n\thooksPath = {s}\n\tfsmonitor = {s}\n[commit]\n\tgpgSign = true\n[gpg]\n\tprogram = {s}\n[user]\n\tuseConfigOnly = true\n",
        .{ hooks, repo.sentinel, repo.sentinel },
    ));
    _ = try fixture.ok(.{ .read_tree = head });
    try repo.write("repo/a.txt", "ten\n");
    _ = try fixture.ok(.{ .add_remove = &.{"a.txt"} });
    const tree = try fixture.ok(.write_tree);
    const commit = try fixture.ok(.{ .commit_tree = .{ .tree = tree, .parent = null, .message = "capture\n", .unix_seconds = 7 } });
    _ = try fixture.ok(.{ .update_ref = .{ .ref = "refs/fx/sessions/s1/w", .new = commit, .old = null } });
    try std.testing.expectEqual(@as(usize, 0), try repo.runs());
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.openDirAbsolute(std.testing.io, try repo.path("store.git/logs"), .{}));
    const object = try fixture.storeOutput(&.{ "cat-file", "-p", commit });
    try std.testing.expect(std.mem.find(u8, object, "author fx capture <capture@fx.invalid> 7 +0000") != null);
    try std.testing.expect(std.mem.find(u8, object, "gpgsig") == null);
}

test "safe git capture store stops a slow trusted filter at its deadline" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try SentinelRepo.init(arena_state.allocator(), tmp.dir);
    const head = try repo.plainOutput(repo.repo, &.{ "rev-parse", "HEAD" });
    const fixture = try StoreFixture.init(repo);
    const slow = try repo.path("slow.sh");
    const marker = try repo.path("filter-finished");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = slow,
        .data = try repo.arena.print("#!/bin/sh\nsleep 2\ntouch '{s}'\ncat\n", .{marker}),
        .flags = .{ .permissions = .fromMode(0o755) },
    });
    const system = try repo.path("system.gitconfig");
    try repo.write("system.gitconfig", try repo.arena.print("[filter \"slow\"]\n\tclean = {s}\n", .{slow}));
    try repo.write("repo/.gitattributes", "a.txt filter=slow\n");
    try repo.write("repo/a.txt", "ten\n");
    _ = try fixture.ok(.{ .read_tree = head });
    const started = io_mod.milliTimestamp();
    try expectFailure(.timeout, try fixture.run(.{ .add_remove = &.{"a.txt"} }, .{ .safe = system }, .{ .timeout_ms = 300 }));
    try std.testing.expect(io_mod.milliTimestamp() - started < 2000);
    // git removed its lock on SIGTERM, and the filter died with its group: it
    // never reaches the line after its sleep.
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.openFileAbsolute(std.testing.io, try repo.path("capture-index.lock"), .{}));
    io_mod.sleep(2500 * std.time.ns_per_ms);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.openFileAbsolute(std.testing.io, marker, .{}));
    // The next capture runs normally once the slow filter is gone.
    try repo.write("repo/.gitattributes", "");
    _ = try fixture.ok(.{ .add_remove = &.{ "a.txt", ".gitattributes" } });
}

test "safe git capture refs are compare-and-swap and keep their chain through maintenance" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try SentinelRepo.init(arena_state.allocator(), tmp.dir);
    const head = try repo.plainOutput(repo.repo, &.{ "rev-parse", "HEAD" });
    const fixture = try StoreFixture.init(repo);
    _ = try fixture.ok(.{ .read_tree = head });
    try repo.write("repo/b.txt", "b\n");
    _ = try fixture.ok(.{ .add_remove = &.{"b.txt"} });
    const tree = try fixture.ok(.write_tree);
    const first = try fixture.ok(.{ .commit_tree = .{ .tree = tree, .parent = null, .message = "one\n", .unix_seconds = 1 } });
    const second = try fixture.ok(.{ .commit_tree = .{ .tree = tree, .parent = first, .message = "two\n", .unix_seconds = 2 } });
    const ref = "refs/fx/sessions/s1/w";
    _ = try fixture.ok(.{ .update_ref = .{ .ref = ref, .new = first, .old = null } });
    try expectFailure(.exited_nonzero, try fixture.run(.{ .update_ref = .{ .ref = ref, .new = first, .old = null } }, .{ .safe = null }, .{}));
    try expectFailure(.exited_nonzero, try fixture.run(.{ .update_ref = .{ .ref = ref, .new = second, .old = second } }, .{ .safe = null }, .{}));
    _ = try fixture.ok(.{ .update_ref = .{ .ref = ref, .new = second, .old = first } });
    try std.testing.expectEqualStrings(second, try fixture.storeOutput(&.{ "rev-parse", ref }));
    try std.testing.expectEqualStrings("b", try fixture.storeOutput(&.{ "cat-file", "-p", try repo.arena.print("{s}:b.txt", .{first}) }));
}

test "safe git capture index clears inherited flags and takes recorded entries" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try SentinelRepo.init(arena_state.allocator(), tmp.dir);
    const old_blob = try repo.plainOutput(repo.repo, &.{ "rev-parse", "HEAD:a.txt" });
    try repo.plain(repo.repo, &.{ "update-index", "--assume-unchanged", "a.txt" });
    try repo.write("repo/a.txt", "two\n");
    const fixture = try StoreFixture.init(repo);
    // The capture starts from a copy of the user's index, flags included.
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = fixture.store.index_file, .data = try readFixtureFile(repo, "repo/.git/index") });

    _ = try fixture.ok(.{ .add_remove = &.{"a.txt"} });
    const stale = try fixture.ok(.write_tree);
    try std.testing.expectEqualStrings("one", try fixture.storeOutput(&.{ "cat-file", "-p", try repo.arena.print("{s}:a.txt", .{stale}) }));

    _ = try fixture.ok(.{ .clear_flag = .{ .flag = .assume_unchanged, .paths = &.{"a.txt"} } });
    _ = try fixture.ok(.{ .add_remove = &.{"a.txt"} });
    _ = try fixture.ok(.{ .index_info = &.{.{ .mode = .file, .oid = old_blob, .path = "out/sparse.txt" }} });
    const tree = try fixture.ok(.write_tree);
    try std.testing.expectEqualStrings("two", try fixture.storeOutput(&.{ "cat-file", "-p", try repo.arena.print("{s}:a.txt", .{tree}) }));
    try std.testing.expectEqualStrings(old_blob, try fixture.storeOutput(&.{ "rev-parse", try repo.arena.print("{s}:out/sparse.txt", .{tree}) }));
    // The user's own index still has the flag.
    try std.testing.expect(std.mem.startsWith(u8, try repo.plainOutput(repo.repo, &.{ "ls-files", "-v", "a.txt" }), "h "));

    // skip-worktree needs its own command: git applies only the first of the
    // two clearing options to each path.
    try repo.plain(repo.repo, &.{ "update-index", "--no-assume-unchanged", "a.txt" });
    try repo.plain(repo.repo, &.{ "update-index", "--skip-worktree", "a.txt" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = fixture.store.index_file, .data = try readFixtureFile(repo, "repo/.git/index") });
    try std.testing.expect(std.mem.startsWith(u8, try fixture.ok(.list_index), "S "));
    _ = try fixture.ok(.{ .clear_flag = .{ .flag = .skip_worktree, .paths = &.{"a.txt"} } });
    try std.testing.expect(std.mem.startsWith(u8, try fixture.ok(.list_index), "H "));

    // A path on disk survives `add_remove` but not `force_remove`.
    _ = try fixture.ok(.{ .add_remove = &.{"a.txt"} });
    try std.testing.expect(std.mem.find(u8, try fixture.ok(.list_index), "\ta.txt") != null);
    _ = try fixture.ok(.{ .force_remove = &.{"a.txt"} });
    try std.testing.expect(std.mem.find(u8, try fixture.ok(.list_index), "\ta.txt") == null);
}

test "safe git lists a repository without running its programs, within an output bound" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try SentinelRepo.init(arena_state.allocator(), tmp.dir);
    try repo.write("repo/b.txt", "b\n");
    try repo.plain(repo.repo, &.{ "add", "b.txt" });
    try repo.plain(repo.repo, &.{ "update-index", "--assume-unchanged", "a.txt" });
    try repo.plain(repo.repo, &.{ "update-index", "--skip-worktree", "b.txt" });
    try repo.write("repo/.gitignore", "ignored\n");
    try repo.write("repo/ignored", "x\n");
    try repo.write("repo/new file", "n\n");
    try repo.plain(repo.repo, &.{ "config", "core.fsmonitor", repo.sentinel });
    try repo.write("repo/a.txt", "ten\n");
    const ready = try repo.ready(repo.repo);
    _ = try repo.runs();

    var env = try repo.childEnvironment(.{ .safe = null });
    const tracked = try expectOk(try listRepositoryWith(repo.arena, ready, repo.repo, .tracked, .{}, &env));
    try std.testing.expect(std.mem.find(u8, tracked, "h 100644 ") != null);
    try std.testing.expect(std.mem.find(u8, tracked, "S 100644 ") != null);
    env = try repo.childEnvironment(.{ .safe = null });
    const untracked = try expectOk(try listRepositoryWith(repo.arena, ready, repo.repo, .untracked, .{}, &env));
    var names: std.ArrayList([]const u8) = .empty;
    var entries = std.mem.splitScalar(u8, untracked, 0);
    while (entries.next()) |name| if (name.len > 0) try names.append(repo.arena, name);
    try std.testing.expectEqual(@as(usize, 2), names.items.len);
    try std.testing.expectEqualStrings(".gitignore", names.items[0]);
    try std.testing.expectEqualStrings("new file", names.items[1]);
    env = try repo.childEnvironment(.{ .safe = null });
    try expectFailure(.output_too_large, try listRepositoryWith(repo.arena, ready, repo.repo, .tracked, .{ .max_stdout = 8 }, &env));
    try std.testing.expectEqual(@as(usize, 0), try repo.runs());

    // From a subdirectory the listing still covers the whole worktree, with
    // paths relative to its root.
    try repo.write("repo/sub/deep.txt", "d\n");
    const sub = try repo.path("repo/sub");
    env = try repo.childEnvironment(.{ .safe = null });
    const from_sub = try expectOk(try listRepositoryWith(repo.arena, try repo.ready(sub), sub, .untracked, .{}, &env));
    try std.testing.expect(std.mem.find(u8, from_sub, "sub/deep.txt\x00") != null);
    try std.testing.expect(std.mem.find(u8, from_sub, "new file\x00") != null);
    try std.testing.expectEqual(@as(usize, 0), try repo.runs());

    // Control: plain git runs the repository's fsmonitor.
    _ = try repo.run(repo.repo, try repo.plainArgv(&.{ "status", "--short" }), .plain);
    try std.testing.expect(try repo.runs() > 0);
}

test "safe git capture store fails instead of dropping a path git refuses" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try SentinelRepo.init(arena_state.allocator(), tmp.dir);
    const head = try repo.plainOutput(repo.repo, &.{ "rev-parse", "HEAD" });
    const fixture = try StoreFixture.init(repo);
    // `git~1` is the NTFS short name of `.git`; git refuses it on every
    // platform (core.protectNTFS) but exits 0.
    try repo.write("repo/git~1/a", "x\n");
    try std.testing.expect(repo_path.isValid("git~1/a"));
    _ = try fixture.ok(.{ .read_tree = head });
    try expectFailure(.path_rejected, try fixture.run(.{ .add_remove = &.{ "a.txt", "git~1/a" } }, .{ .safe = null }, .{}));
}

test "safe git capture store follows the repository object format" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try SentinelRepo.init(arena_state.allocator(), tmp.dir);
    const wide = try repo.path("wide");
    try std.Io.Dir.cwd().createDirPath(std.testing.io, wide);
    try repo.plain(wide, &.{ "init", "-q", "--template=", "--object-format=sha256", "-b", "main" });
    try repo.write("wide/a.txt", "one\n");
    try repo.plain(wide, &.{ "add", "a.txt" });
    try repo.commit(wide);
    const head = try repo.plainOutput(wide, &.{ "rev-parse", "HEAD" });
    try std.testing.expectEqual(@as(usize, 64), head.len);

    const fixture = try StoreFixture.initFormat(repo, .sha256, "wide");
    try repo.write("wide/a.txt", "two\n");
    _ = try fixture.ok(.{ .read_tree = head });
    _ = try fixture.ok(.{ .add_remove = &.{"a.txt"} });
    const tree = try fixture.ok(.write_tree);
    try repo.plain(wide, &.{ "add", "-A" });
    try std.testing.expectEqualStrings(try repo.plainOutput(wide, &.{"write-tree"}), tree);
}

test "safe git capture store records the user's file mode setting, not git's default" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try SentinelRepo.init(arena_state.allocator(), tmp.dir);
    const head = try repo.plainOutput(repo.repo, &.{ "rev-parse", "HEAD" });
    try repo.plain(repo.repo, &.{ "config", "core.fileMode", "false" });
    // Permissions apply only when a file is created, so recreate it.
    const file = try repo.path("repo/a.txt");
    try std.Io.Dir.deleteFileAbsolute(std.testing.io, file);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = file, .data = "one\n", .flags = .{ .permissions = .fromMode(0o755) } });
    var fixture = try StoreFixture.init(repo);

    // Without the setting the store records the executable bit the user's git ignores.
    _ = try fixture.ok(.{ .read_tree = head });
    _ = try fixture.ok(.{ .add_remove = &.{"a.txt"} });
    const unconverted = try fixture.ok(.write_tree);
    try std.testing.expect(std.mem.startsWith(u8, try fixture.storeOutput(&.{ "ls-tree", unconverted, "a.txt" }), "100755"));

    fixture.store.conversions = .{ .file_mode = false };
    _ = try fixture.ok(.{ .read_tree = head });
    _ = try fixture.ok(.{ .add_remove = &.{"a.txt"} });
    const tree = try fixture.ok(.write_tree);
    try repo.plain(repo.repo, &.{ "add", "-A" });
    try std.testing.expectEqualStrings(try repo.plainOutput(repo.repo, &.{"write-tree"}), tree);
}

test "safe git capture store uses a trusted global LFS filter and fails when a required one is missing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try SentinelRepo.init(arena_state.allocator(), tmp.dir);
    const head = try repo.plainOutput(repo.repo, &.{ "rev-parse", "HEAD" });
    const fixture = try StoreFixture.init(repo);
    const fake_lfs = try repo.path("fake-lfs.sh");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = fake_lfs,
        .data = "#!/bin/sh\ncat > /dev/null\nprintf 'version https://git-lfs.github.com/spec/v1\\noid sha256:0\\nsize 4\\n'\n",
        .flags = .{ .permissions = .fromMode(0o755) },
    });
    try repo.write("repo/.gitattributes", "big.bin filter=lfs\n");
    try repo.write("repo/big.bin", "data");
    try repo.write("home/.gitconfig", try repo.arena.print("[filter \"lfs\"]\n\tclean = {s}\n\trequired = true\n", .{fake_lfs}));
    _ = try fixture.ok(.{ .read_tree = head });
    _ = try fixture.ok(.{ .add_remove = &.{ ".gitattributes", "big.bin" } });
    const tree = try fixture.ok(.write_tree);
    try std.testing.expect(std.mem.startsWith(u8, try fixture.storeOutput(&.{ "cat-file", "-p", try repo.arena.print("{s}:big.bin", .{tree}) }), "version https://git-lfs"));
    try repo.plain(repo.repo, &.{ "add", "-A" });
    try std.testing.expectEqualStrings(try repo.plainOutput(repo.repo, &.{"write-tree"}), tree);

    // A required filter that resolves nowhere on the capture PATH fails the
    // capture visibly instead of storing unfiltered content.
    try repo.write("home/.gitconfig", "[filter \"lfs\"]\n\tclean = fx-missing-lfs clean -- %f\n\trequired = true\n");
    try repo.write("repo/big.bin", "more");
    try expectFailure(.exited_nonzero, try fixture.run(.{ .add_remove = &.{"big.bin"} }, .{ .safe = null }, .{}));
}

test "safe git capture store starts nothing once a shared deadline has passed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try SentinelRepo.init(arena_state.allocator(), tmp.dir);
    const fixture = try StoreFixture.init(repo);
    const io = std.testing.io;
    const past: std.Io.Clock.Timestamp = .fromNow(io, .{ .clock = .awake, .raw = .fromMilliseconds(-1) });
    // An executable that cannot start tells a spawn attempt (`spawn_failed`)
    // apart from a run that never started (`timeout`).
    var unstartable = fixture;
    unstartable.ready = .{ .executable = try repo.path("no-such-git") };
    try expectFailure(.timeout, try unstartable.run(.{ .add_remove = &.{"a.txt"} }, .{ .safe = null }, .{ .deadline = past }));
    var scratch = try std.Io.Dir.openDirAbsolute(io, fixture.store.scratch_dir, .{ .iterate = true });
    defer scratch.close(io);
    var entries = scratch.iterate();
    try std.testing.expect(try entries.next(io) == null);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.openFileAbsolute(io, try repo.path("capture-index"), .{}));
}

test "safe git capture PATH covers the directories trusted for git itself" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    var dirs = std.mem.splitScalar(u8, capture_path, ':');
    var count: usize = 0;
    while (dirs.next()) |dir| : (count += 1) try std.testing.expect(std.Io.Dir.path.isAbsolute(dir));
    try std.testing.expectEqual(@as(usize, 6), count);
    for ([_][]const u8{ "/usr/bin/git", "/bin/git", "/usr/local/bin/git", "/opt/homebrew/bin/git", "/opt/local/bin/git", "/run/current-system/sw/bin/git" }) |git| {
        const dir = std.Io.Dir.path.dirname(git).?;
        var found = false;
        var it = std.mem.splitScalar(u8, capture_path, ':');
        while (it.next()) |entry| found = found or std.mem.eql(u8, entry, dir);
        try std.testing.expect(found);
    }
}

test "safe git capture store runs a real git-lfs installed where git is trusted" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    const lfs_installed = for ([_][]const u8{ "/opt/homebrew/bin/git-lfs", "/usr/local/bin/git-lfs" }) |candidate| {
        _ = std.Io.Dir.cwd().statFile(std.testing.io, candidate, .{}) catch continue;
        break true;
    } else false;
    if (!lfs_installed) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try SentinelRepo.init(arena_state.allocator(), tmp.dir);
    const head = try repo.plainOutput(repo.repo, &.{ "rev-parse", "HEAD" });
    const fixture = try StoreFixture.init(repo);
    // The filter is named by bare command, as `git lfs install` writes it.
    try repo.write("home/.gitconfig", "[filter \"lfs\"]\n\tclean = git-lfs clean -- %f\n\tsmudge = git-lfs smudge -- %f\n\tprocess = git-lfs filter-process\n\trequired = true\n");
    try repo.write("repo/.gitattributes", "*.bin filter=lfs diff=lfs merge=lfs -text\n");
    try repo.write("repo/big.bin", "large content\n");
    _ = try fixture.ok(.{ .read_tree = head });
    _ = try fixture.ok(.{ .add_remove = &.{ ".gitattributes", "big.bin" } });
    const tree = try fixture.ok(.write_tree);
    const blob = try fixture.storeOutput(&.{ "cat-file", "-p", try repo.arena.print("{s}:big.bin", .{tree}) });
    try std.testing.expect(std.mem.startsWith(u8, blob, "version https://git-lfs.github.com/spec/v1"));
}

test "safe git reads repository facts as data, without running its programs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try SentinelRepo.init(arena_state.allocator(), tmp.dir);
    try repo.plain(repo.repo, &.{ "config", "core.fsmonitor", repo.sentinel });
    try repo.plain(repo.repo, &.{ "config", "core.autocrlf", "input" });
    try repo.plain(repo.repo, &.{ "config", "core.fileMode", "false" });
    try repo.plain(repo.repo, &.{ "config", "core.splitIndex", "yes" });
    try repo.write("repo/a.txt", "ten\n");
    const ready = try repo.ready(repo.repo);
    _ = try repo.runs();
    var env = try repo.childEnvironment(.{ .safe = null });
    const facts = (try repositoryFactsWith(repo.arena, ready, repo.repo, .{}, &env)).?;
    try std.testing.expectEqualStrings(try repo.plainOutput(repo.repo, &.{ "rev-parse", "HEAD" }), facts.head.?);
    try std.testing.expectEqualStrings(repo.repo, facts.work_tree);
    try std.testing.expectEqualStrings(try repo.path("repo/.git"), facts.git_dir);
    try std.testing.expectEqualStrings(try repo.path("repo/.git"), facts.common_dir);
    try std.testing.expectEqual(ObjectFormat.sha1, facts.object_format);
    try std.testing.expect(facts.split_index);
    try std.testing.expect(!facts.sparse_index);
    try std.testing.expectEqual(false, facts.conversions.file_mode.?);
    try std.testing.expect(facts.conversions.autocrlf.? == .input);
    try std.testing.expect(facts.conversions.eol == null);
    try std.testing.expectEqual(@as(usize, 0), try repo.runs());

    // An unborn repository has no HEAD but still reports its format.
    const unborn = try repo.path("unborn");
    try std.Io.Dir.cwd().createDirPath(std.testing.io, unborn);
    try repo.plain(unborn, &.{ "init", "-q", "--template=", "-b", "main" });
    env = try repo.childEnvironment(.{ .safe = null });
    const empty = (try repositoryFactsWith(repo.arena, try repo.ready(unborn), unborn, .{}, &env)).?;
    try std.testing.expect(empty.head == null);
}

test "safe git repository facts fail when HEAD is broken instead of reporting unborn" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try SentinelRepo.init(arena_state.allocator(), tmp.dir);
    const ready = try repo.ready(repo.repo);
    const commit = try repo.plainOutput(repo.repo, &.{ "rev-parse", "HEAD" });
    const tree = try repo.plainOutput(repo.repo, &.{ "rev-parse", "HEAD^{tree}" });
    const blob = try repo.plainOutput(repo.repo, &.{ "rev-parse", "HEAD:a.txt" });
    try std.testing.expectEqualStrings("refs/heads/main", try repo.plainOutput(repo.repo, &.{ "symbolic-ref", "HEAD" }));

    const Case = struct { file: []const u8, data: []const u8 };
    const cases = [_]Case{
        // The branch exists but names an object the repository lacks.
        .{ .file = "repo/.git/refs/heads/main", .data = "1111111111111111111111111111111111111111\n" },
        // The branch file is corrupt.
        .{ .file = "repo/.git/refs/heads/main", .data = "garbage\n" },
        // The branch exists but names a tree.
        .{ .file = "repo/.git/refs/heads/main", .data = try repo.arena.print("{s}\n", .{tree}) },
        // HEAD is detached at a tree, then at a blob.
        .{ .file = "repo/.git/HEAD", .data = try repo.arena.print("{s}\n", .{tree}) },
        .{ .file = "repo/.git/HEAD", .data = try repo.arena.print("{s}\n", .{blob}) },
    };
    for (cases) |case| {
        try repo.write("repo/.git/HEAD", "ref: refs/heads/main\n");
        try repo.write("repo/.git/refs/heads/main", try repo.arena.print("{s}\n", .{commit}));
        try repo.write(case.file, case.data);
        var env = try repo.childEnvironment(.{ .safe = null });
        try std.testing.expect(try repositoryFactsWith(repo.arena, ready, repo.repo, .{}, &env) == null);
    }

    // A symbolic HEAD to a branch that does not exist is unborn, even with
    // other branches present.
    try repo.write("repo/.git/refs/heads/main", try repo.arena.print("{s}\n", .{commit}));
    try repo.write("repo/.git/HEAD", "ref: refs/heads/next\n");
    var env = try repo.childEnvironment(.{ .safe = null });
    const unborn = (try repositoryFactsWith(repo.arena, ready, repo.repo, .{}, &env)).?;
    try std.testing.expect(unborn.head == null);
}

test "safe git capture store resolves refs and lists its own index" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try SentinelRepo.init(arena_state.allocator(), tmp.dir);
    const head = try repo.plainOutput(repo.repo, &.{ "rev-parse", "HEAD" });
    const fixture = try StoreFixture.init(repo);
    try std.testing.expectEqualStrings("", try fixture.ok(.{ .resolve_ref = "refs/fx/sessions/s1/w" }));
    _ = try fixture.ok(.{ .read_tree = head });
    const listed = try fixture.ok(.list_index);
    try std.testing.expect(std.mem.startsWith(u8, listed, "H 100644 "));
    try std.testing.expect(std.mem.endsWith(u8, listed, "\ta.txt\x00") or std.mem.endsWith(u8, listed, "\ta.txt"));
    const tree = try fixture.ok(.write_tree);
    const commit = try fixture.ok(.{ .commit_tree = .{ .tree = tree, .parent = null, .message = "capture\n", .unix_seconds = 1 } });
    _ = try fixture.ok(.{ .update_ref = .{ .ref = "refs/fx/sessions/s1/w", .new = commit, .old = null } });
    try std.testing.expectEqualStrings(commit, try fixture.ok(.{ .resolve_ref = "refs/fx/sessions/s1/w" }));
}

test "safe git capture store finds a filter named by bare command on the route's PATH" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try SentinelRepo.init(arena_state.allocator(), tmp.dir);
    const head = try repo.plainOutput(repo.repo, &.{ "rev-parse", "HEAD" });
    // A stand-in for a git-lfs that a package manager put on the trusted
    // PATH, named by bare command as `git lfs install` writes it.
    const bin = try repo.path("trusted-bin");
    try std.Io.Dir.cwd().createDirPath(std.testing.io, bin);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = try std.Io.Dir.path.join(repo.arena, &.{ bin, "git-lfs" }),
        .data = "#!/bin/sh\ncat > /dev/null\nprintf 'version https://git-lfs.github.com/spec/v1\\noid sha256:1\\nsize 4\\n'\n",
        .flags = .{ .permissions = .fromMode(0o755) },
    });
    var fixture = try StoreFixture.init(repo);
    fixture.path = try repo.arena.print("{s}:{s}", .{ bin, capture_path });
    try repo.write("home/.gitconfig", "[filter \"lfs\"]\n\tclean = git-lfs clean -- %f\n\trequired = true\n");
    try repo.write("repo/.gitattributes", "*.bin filter=lfs\n");
    try repo.write("repo/big.bin", "data");
    _ = try fixture.ok(.{ .read_tree = head });
    _ = try fixture.ok(.{ .add_remove = &.{ ".gitattributes", "big.bin" } });
    const tree = try fixture.ok(.write_tree);
    const blob = try fixture.storeOutput(&.{ "cat-file", "-p", try repo.arena.print("{s}:big.bin", .{tree}) });
    try std.testing.expect(std.mem.startsWith(u8, blob, "version https://git-lfs.github.com/spec/v1\noid sha256:1"));
}

test "safe git preparation within a passed deadline refuses instead of running on" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try SentinelRepo.init(arena_state.allocator(), tmp.dir);
    const io = std.testing.io;
    try std.testing.expect(try prepare(repo.arena, repo.repo) == .ready);
    const past: std.Io.Clock.Timestamp = .fromNow(io, .{ .clock = .awake, .raw = .fromMilliseconds(-1) });
    try std.testing.expect(try prepareWithin(repo.arena, repo.repo, .{ .deadline = past }) == .refused);
    // The version check, too, when its answer is not cached yet.
    {
        version_lock.lockUncancelable(io);
        defer version_lock.unlock(io);
        cached_version = null;
    }
    try std.testing.expect(try prepareWithin(repo.arena, repo.repo, .{ .deadline = past }) == .refused);
    // A version check cut off at the deadline leaves no answer to reuse.
    try std.testing.expect(cached_version == null);
}

test "safe git index listings refuse records that are not git's" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const oid = "0123456789abcdef0123456789abcdef01234567";
    for ([_][]const u8{
        "H 100644 " ++ oid ++ " 0 extra\ta\x00",
        "H 100644 " ++ oid ++ "\ta\x00",
        "HH 100644 " ++ oid ++ " 0\ta\x00",
        "H 100600 " ++ oid ++ " 0\ta\x00",
        "H 100644 " ++ oid ++ " 0\t\x00",
        "H 100644 " ++ oid ++ " 0 a\x00",
    }) |listing| try std.testing.expectError(error.Malformed, parseStageListing(arena, listing));
    const entries = try parseStageListing(arena, "s 100755 " ++ oid ++ " 0\tbin/run\x00M 160000 " ++ oid ++ " 1\tsub\x00M 160000 " ++ oid ++ " 2\tsub\x00");
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expect(entries[0].mode == .executable and entries[0].skip_worktree and entries[0].assume_unchanged);
    try std.testing.expect(entries[1].mode == .gitlink and !entries[1].skip_worktree);
}

test "safe git parses fuzzed index listings and version lines without inventing entries" {
    try std.testing.fuzz({}, fuzzGitOutput, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "H 100644 0123456789abcdef0123456789abcdef01234567 0\ta.txt\x00",
            "h 100755 0123456789abcdef0123456789abcdef01234567 0\tbin/run\x00S 120000 0123456789abcdef0123456789abcdef01234567 0\tlink\x00",
            "M 160000 0123456789abcdef0123456789abcdef01234567 1\tsub\x00M 160000 0123456789abcdef0123456789abcdef01234567 2\tsub\x00",
            "H 100644 x 0\ttab\tin name\x00",
            "git version 2.39.5 (Apple Git-154)\n",
            "H 100644\x00",
            "\x00\x00\t",
        }) ++ @import("fuzz_corpus").safe_git_output.*),
    });
}

fn fuzzGitOutput(_: void, smith: *std.testing.Smith) anyerror!void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buffer: [4096]u8 = undefined;
    const bytes = buffer[0..@intCast(smith.slice(&buffer))];
    _ = classifyVersionAtLeast(bytes, minimum_minor);
    const entries = parseStageListing(arena, bytes) catch return;
    // What parses writes back as git would, and parses to the same entries.
    var again: std.ArrayList(u8) = .empty;
    for (entries) |entry| {
        try std.testing.expect(entry.path.len > 0 and std.mem.findScalar(u8, entry.path, 0) == null);
        const tag: u8 = if (entry.skip_worktree) 'S' else 'H';
        try again.print(arena, "{c} {s} {s} 0\t{s}\x00", .{ if (entry.assume_unchanged) std.ascii.toLower(tag) else tag, entry.mode.text(), entry.oid, entry.path });
    }
    const reparsed = try parseStageListing(arena, again.items);
    try std.testing.expectEqual(entries.len, reparsed.len);
    for (entries, reparsed) |a, b| {
        try std.testing.expectEqualStrings(a.path, b.path);
        try std.testing.expectEqualStrings(a.oid, b.oid);
        try std.testing.expectEqual(a.mode, b.mode);
        try std.testing.expectEqual(a.assume_unchanged, b.assume_unchanged);
        try std.testing.expectEqual(a.skip_worktree, b.skip_worktree);
    }
}
