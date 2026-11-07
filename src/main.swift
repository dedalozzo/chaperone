// Chaperone.app: runs one allowlisted script as its responsible process.
//
// # Why this exists
//
// On the first launch of every newly built, unnotarized program, syspolicyd
// runs an XProtect scan. It skips the scan when the program's *responsible
// process* is an app listed (and switched on) in System Settings > Privacy &
// Security > Developer Tools; tccd answers that question for the
// kTCCServiceDeveloperTool service.
//
// The responsible process is inherited from parent to child, unless a spawner
// disclaims it. Shells under agent tools and terminal multiplexers often lose
// it, so the programs they start get scanned. Only an app that LaunchServices
// starts (`open -a …`) becomes a *fresh* responsible process.
//
// Chaperone is that app. `open` starts it; it spawns the script without
// disclaiming responsibility, so the script and everything the script starts
// stay attributed to Chaperone.app. With Chaperone listed under Developer
// Tools, none of them is scanned.
//
// # How it is driven
//
// The `chaperone` shim (a bash script at the root of the repo) calls
//
//     open -n -g -a ~/Applications/Chaperone.app --env K=V … \
//          --args [--cwd DIR] [--log FILE] [--status FILE] -- /abs/script [args…]
//
// `-n` gives each run its own instance, `-g` keeps it in the background, and
// Info.plist sets LSBackgroundOnly, so the app never has a window, a Dock icon
// or a prompt. It uses no AppKit at all: it is a plain command-line program
// inside an app bundle, because the Developer Tools picker accepts only apps.
//
// # The status file
//
// Each event is one `key=value` line, written and fsync'ed as it happens:
//
//     app=<pid of this Chaperone instance>   first, before any check
//     pid=<pid of the script>                once the script is running
//     exit=<code>  or  signal=<n>            when the script has ended
//
// A refusal writes `refused=<reason>` and then `exit=126` instead. An
// internal failure after the script started writes `exit=125`. The shim's
// `--wait` polls this file for the final line.
//
// # Lifecycle
//
// parse arguments → open the status file → check the script against the
// allowlist → chdir → spawn the script → wait for it → write its result →
// quit. There is no run loop: the app lives exactly as long as the script.

import Darwin
import Foundation
import os

// MARK: - Constants and global state

/// Unified-log subsystem; read it with
/// `/usr/bin/log show --predicate 'subsystem == "io.github.dedalozzo.chaperone"'`.
let subsystem = "io.github.dedalozzo.chaperone"
let logger = Logger(subsystem: subsystem, category: "run")

/// Exit code reported when Chaperone refuses to run a script (same meaning
/// as a shell's "found but cannot execute").
let refusedCode: Int32 = 126

/// Exit code reported when Chaperone itself fails after starting the script.
let failureCode: Int32 = 125

/// The script's process group id (equal to the script's pid, because it is
/// spawned as a group leader). The signal handler reads it to forward
/// SIGTERM/SIGINT/SIGHUP to the whole run. Zero until the script starts.
/// `nonisolated(unsafe)`: written once on the main thread, read from a
/// signal handler; a plain aligned integer is safe for that.
nonisolated(unsafe) var childGroup: pid_t = 0

/// The status file, if one was given and could be opened. Global so that
/// `refuse` can report from anywhere.
nonisolated(unsafe) var status: StatusFile?

// MARK: - Options

/// What `open --args` handed us.
struct Options {
    /// Working directory for the script. Default: the user's home directory.
    var cwd: String?
    /// File that receives the script's stdout and stderr (appended).
    /// Default: /dev/null.
    var log: String?
    /// Status file (see the header). Default: none.
    var status: String?
    /// Absolute path of the script to run.
    var script: String?
    /// Arguments for the script.
    var args: [String] = []
    /// A parse error. Reported only once the status file is open, so the
    /// caller sees it there instead of waiting for a line that never comes.
    var error: String?
}

/// Parses `[--cwd DIR] [--log FILE] [--status FILE] -- /abs/script [args…]`.
///
/// Everything after `--` (or after the first argument that is not an
/// option) belongs to the script, even if it starts with `-`. Never exits:
/// problems are recorded in `Options.error`.
func parse(_ argv: [String]) -> Options {
    var o = Options()
    var i = 0

    /// Consumes the value of the option at `i`, or records an error.
    func value(_ name: String) -> String? {
        i += 1
        guard i < argv.count else {
            o.error = "\(name) needs a value"
            return nil
        }
        return argv[i]
    }

    while i < argv.count {
        let a = argv[i]
        switch a {
        case "--cwd": o.cwd = value(a)
        case "--log": o.log = value(a)
        case "--status": o.status = value(a)
        case "--":
            i += 1
            if i < argv.count {
                o.script = argv[i]
                o.args = Array(argv[(i + 1)...])
            }
            return o
        default:
            // Very old LaunchServices passed a process serial number as
            // `-psn_0_12345`; ignore it if it ever shows up.
            if a.hasPrefix("-psn_") { break }
            if a.hasPrefix("-") {
                o.error = "unknown option \(a)"
                return o
            }
            o.script = a
            o.args = Array(argv[(i + 1)...])
            return o
        }
        i += 1
    }
    return o
}

// MARK: - Status file and refusals

/// Append-only writer for the status file.
///
/// Uses a raw descriptor and fsync after every line, so a reader polling the
/// file (the shim's `--wait`) sees each event at once, and an event written
/// just before the app quits is never lost in a buffer.
final class StatusFile {
    private let fd: Int32

    /// Opens (and truncates) `path`. Returns nil, after logging why, when no
    /// path was given or the file cannot be opened; the run still goes ahead,
    /// only without a status file.
    init?(_ path: String?) {
        guard let path else { return nil }
        // O_TRUNC: a stale exit= line from an earlier run must not be read as
        // this run's result. O_CLOEXEC: the script must not inherit it.
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND | O_CLOEXEC, 0o644)
        if fd < 0 {
            logger.error("cannot open status file \(path, privacy: .public): \(String(cString: strerror(errno)), privacy: .public)")
            return nil
        }
        self.fd = fd
    }

    /// Writes one line and flushes it to disk.
    func write(_ line: String) {
        let text = line + "\n"
        text.withCString { p in _ = Darwin.write(fd, p, strlen(p)) }
        fsync(fd)
    }
}

/// Keeps a value on one status-file line (paths may contain newlines).
func oneLine(_ s: String) -> String {
    s.replacingOccurrences(of: "\n", with: "\\n")
}

/// Refuses the run: logs `reason` to the unified log and the status file,
/// writes `exit=126`, and quits. Used for every check that fails before the
/// script starts, so nothing unchecked ever runs.
func refuse(_ reason: String) -> Never {
    let reason = oneLine(reason)
    logger.error("refused: \(reason, privacy: .public)")
    status?.write("refused=\(reason)")
    status?.write("exit=\(refusedCode)")
    exit(refusedCode)
}

// MARK: - Checks

/// The user's home directory, from the user database.
///
/// Deliberately not `$HOME`: the caller's environment is passed through to
/// the app, and a caller must not be able to point Chaperone at an allowlist
/// of its own choosing.
func homeDirectory() -> String {
    if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
        return String(cString: dir)
    }
    refuse("cannot find the home directory of uid \(getuid())")
}

/// `realpath(3)`: absolute, with `.`/`..` and symlinks resolved; nil if the
/// path does not exist (errno says why).
func realPath(_ path: String) -> String? {
    guard let r = realpath(path, nil) else { return nil }
    defer { free(r) }
    return String(cString: r)
}

/// Refuses unless `path` is owned by the current user and is neither group-
/// nor world-writable; otherwise someone else could change what runs.
/// Returns the file's `stat` for further checks. `what` names the file in
/// the refusal ("script", "allowlist").
func safeOwnership(_ path: String, _ what: String) -> stat {
    var st = stat()
    guard stat(path, &st) == 0 else {
        refuse("cannot stat \(what) \(path): \(String(cString: strerror(errno)))")
    }
    if st.st_uid != getuid() {
        refuse("\(what) \(path) is owned by uid \(st.st_uid), not by uid \(getuid())")
    }
    if st.st_mode & (S_IWGRP | S_IWOTH) != 0 {
        refuse("\(what) \(path) is group- or world-writable")
    }
    return st
}

/// Reads `~/.config/chaperone/allow`: one absolute path prefix per line,
/// blank lines and `#` comments ignored.
///
/// Refuses if the file is missing (no allowlist means nothing may run) or is
/// not safely owned. Each prefix is resolved with realpath when it exists, so
/// it compares equal to the resolved script path (e.g. /tmp vs /private/tmp),
/// and loses any trailing slash. Relative lines and a bare `/` (which would
/// allow everything) are ignored with a warning in the unified log.
func allowedPrefixes() -> [String] {
    let path = homeDirectory() + "/.config/chaperone/allow"
    guard access(path, F_OK) == 0 else { refuse("no allowlist at \(path): every script is refused") }
    _ = safeOwnership(path, "allowlist")
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        refuse("cannot read the allowlist \(path)")
    }
    var prefixes: [String] = []
    for raw in text.split(whereSeparator: \.isNewline) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        guard line.hasPrefix("/") else {
            logger.warning("allowlist line is not an absolute path, ignored: \(line, privacy: .public)")
            continue
        }
        var prefix = realPath(line) ?? line
        while prefix.count > 1 && prefix.hasSuffix("/") { prefix.removeLast() }
        if prefix == "/" {
            logger.warning("allowlist prefix / would allow everything, ignored")
            continue
        }
        prefixes.append(prefix)
    }
    return prefixes
}

/// Checks that `script` may run, and returns its resolved path.
///
/// The script must be absolute; its real path (symlinks resolved, so a link
/// inside an allowed directory cannot point outside it) must equal an allowed
/// prefix or lie below one at a path-component boundary (`/a/b` allows
/// `/a/b/x.sh`, not `/a/bc/x.sh`); and it must be a regular, executable file
/// that only the user can change. The resolved path is what gets spawned.
///
/// Note: the file is checked and then spawned, so its contents could change
/// in between. The ownership rules make that possible only for the user.
func checkScript(_ script: String) -> String {
    guard script.hasPrefix("/") else { refuse("the script must be an absolute path: \(script)") }
    guard let real = realPath(script) else {
        refuse("cannot resolve the script \(script): \(String(cString: strerror(errno)))")
    }
    let prefixes = allowedPrefixes()
    guard prefixes.contains(where: { real == $0 || real.hasPrefix($0 + "/") }) else {
        refuse("\(real) is not under a prefix listed in the allowlist")
    }
    let st = safeOwnership(real, "script")
    if st.st_mode & S_IFMT != S_IFREG { refuse("the script \(real) is not a regular file") }
    if st.st_mode & S_IXUSR == 0 { refuse("the script \(real) is not executable") }
    return real
}

// MARK: - Running the script

/// Starts the script with `posix_spawn` and returns its pid; refuses if it
/// cannot start (e.g. no `#!` line, or the log file cannot be opened).
///
/// - stdin is /dev/null; stdout and stderr are appended to `log`.
/// - The environment is this app's own (`environ`): whatever `open --env`
///   and LaunchServices gave it, unchanged.
/// - The working directory is inherited (`main` has already chdir'ed).
/// - The script leads a new process group, so a forwarded signal reaches
///   every process of the run, not only the script.
/// - The signal mask is cleared and, with POSIX_SPAWN_CLOEXEC_DEFAULT, no
///   descriptor leaks except 0, 1 and 2.
/// - Deliberately NO responsibility-disclaim attribute: the script and its
///   children must keep Chaperone.app as their responsible process. That is
///   the whole point of the app.
func spawn(_ path: String, _ args: [String], log: String) -> pid_t {
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, log, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    posix_spawn_file_actions_adddup2(&actions, 1, 2)

    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT
    posix_spawnattr_setflags(&attr, Int16(flags))
    posix_spawnattr_setpgroup(&attr, 0)  // 0: a new group whose id is the child's pid
    var empty = sigset_t()
    sigemptyset(&empty)
    posix_spawnattr_setsigmask(&attr, &empty)

    // argv[0] is the resolved path; the C strings are freed after the spawn.
    var argv: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) }
    argv.append(nil)
    defer { argv.forEach { free($0) } }

    var pid: pid_t = 0
    let rc = posix_spawn(&pid, path, &actions, &attr, argv, environ)
    if rc != 0 { refuse("cannot start \(path): \(String(cString: strerror(rc)))") }
    return pid
}

/// Makes SIGTERM, SIGINT and SIGHUP sent to Chaperone stop the run: each is
/// forwarded to the script's process group, and Chaperone keeps waiting so
/// it can record `signal=<n>`. This is how a run is cancelled
/// (`kill <app pid>` from the status file). The handler only calls kill(2),
/// which is async-signal-safe. Darwin's signal(3) sets SA_RESTART, so the
/// wait in `main` resumes after the handler.
func forwardSignals() {
    for sig in [SIGTERM, SIGINT, SIGHUP] {
        signal(sig) { s in
            if childGroup > 0 { kill(-childGroup, s) }
        }
    }
}

// MARK: - Main

func main() -> Never {
    let options = parse(Array(CommandLine.arguments.dropFirst()))

    // The status file comes first, so every later refusal is reported there.
    status = StatusFile(options.status)
    status?.write("app=\(getpid())")
    if let error = options.error { refuse(error) }

    guard let script = options.script else { refuse("no script given") }
    let path = checkScript(script)

    let cwd = options.cwd ?? homeDirectory()
    guard chdir(cwd) == 0 else { refuse("cannot change to \(cwd): \(String(cString: strerror(errno)))") }

    let log = options.log ?? "/dev/null"
    forwardSignals()
    let pid = spawn(path, options.args, log: log)
    childGroup = pid
    status?.write("pid=\(pid)")
    logger.info("started \(path, privacy: .public) pid=\(pid) cwd=\(cwd, privacy: .public) log=\(log, privacy: .public)")

    // Wait for the script itself (not for processes it left in the
    // background), retrying when a forwarded signal interrupts the wait.
    var raw: Int32 = 0
    while waitpid(pid, &raw, 0) == -1 {
        if errno != EINTR {
            logger.error("waitpid: \(String(cString: strerror(errno)), privacy: .public)")
            status?.write("exit=\(failureCode)")
            exit(failureCode)
        }
    }

    // Decode the wait status by hand: Swift does not import the WIFEXITED /
    // WEXITSTATUS / WTERMSIG macros. Low 7 bits: the terminating signal, or
    // 0 for a normal exit, whose code is in the next byte.
    let sig = raw & 0x7f
    if sig == 0 {
        let code = (raw >> 8) & 0xff
        status?.write("exit=\(code)")
        logger.info("\(path, privacy: .public) pid=\(pid) exit=\(code)")
    } else {
        status?.write("signal=\(sig)")
        logger.info("\(path, privacy: .public) pid=\(pid) signal=\(sig)")
    }
    // Chaperone's own exit code carries no meaning: the result is in the
    // status file.
    exit(0)
}

main()
