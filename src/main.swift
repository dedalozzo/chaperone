// Chaperone: runs one allowlisted script as its responsible process.
//
// LaunchServices starts this app (through `open`), so the app becomes a fresh
// responsible process. The script it spawns, and every program the script
// starts, inherits that responsibility. When Chaperone.app is listed in
// System Settings > Privacy & Security > Developer Tools, syspolicyd skips the
// XProtect first-launch scan for all of them.
//
// Arguments (normally passed by the `chaperone` shim through `open --args`):
//   [--cwd DIR] [--log FILE] [--status FILE] -- /abs/script [args...]
//
// Status file lines: app=<this pid>, pid=<script pid>, then exit=<code> or
// signal=<n>. A refusal writes refused=<reason> and exit=126.

import Darwin
import Foundation
import os

let subsystem = "io.github.dedalozzo.chaperone"
let logger = Logger(subsystem: subsystem, category: "run")
let refusedCode: Int32 = 126

// The script's process group, for forwarding SIGTERM/SIGINT/SIGHUP.
nonisolated(unsafe) var childGroup: pid_t = 0

struct Options {
    var cwd: String?
    var log: String?
    var status: String?
    var script: String?
    var args: [String] = []
    var error: String?
}

// MARK: - Status file

final class StatusFile {
    private let fd: Int32

    init?(_ path: String?) {
        guard let path else { return nil }
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND | O_CLOEXEC, 0o644)
        if fd < 0 {
            logger.error("cannot open status file \(path, privacy: .public): \(String(cString: strerror(errno)), privacy: .public)")
            return nil
        }
        self.fd = fd
    }

    func write(_ line: String) {
        let text = line + "\n"
        text.withCString { p in _ = Darwin.write(fd, p, strlen(p)) }
        fsync(fd)
    }
}

nonisolated(unsafe) var status: StatusFile?

func oneLine(_ s: String) -> String {
    s.replacingOccurrences(of: "\n", with: "\\n")
}

func refuse(_ reason: String) -> Never {
    let reason = oneLine(reason)
    logger.error("refused: \(reason, privacy: .public)")
    status?.write("refused=\(reason)")
    status?.write("exit=\(refusedCode)")
    exit(refusedCode)
}

// MARK: - Arguments

func parse(_ argv: [String]) -> Options {
    var o = Options()
    var i = 0
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
            if a.hasPrefix("-psn_") { break }  // old LaunchServices process serial number
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

// MARK: - Checks

func homeDirectory() -> String {
    // Not $HOME: the caller's environment passes through and must not move the allowlist.
    if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
        return String(cString: dir)
    }
    refuse("cannot find the home directory of uid \(getuid())")
}

func realPath(_ path: String) -> String? {
    guard let r = realpath(path, nil) else { return nil }
    defer { free(r) }
    return String(cString: r)
}

/// Owned by the user, not group- or world-writable.
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

/// Returns the resolved path of an allowed script, or refuses.
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

// MARK: - Run

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
    // Own process group (so signals can be forwarded to the whole run), an
    // empty signal mask, and no other inherited descriptors. Deliberately no
    // responsibility-disclaim attribute: the children must stay attributed
    // to this app.
    let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT
    posix_spawnattr_setflags(&attr, Int16(flags))
    posix_spawnattr_setpgroup(&attr, 0)
    var empty = sigset_t()
    sigemptyset(&empty)
    posix_spawnattr_setsigmask(&attr, &empty)

    var argv: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) }
    argv.append(nil)
    defer { argv.forEach { free($0) } }

    var pid: pid_t = 0
    let rc = posix_spawn(&pid, path, &actions, &attr, argv, environ)
    if rc != 0 { refuse("cannot start \(path): \(String(cString: strerror(rc)))") }
    return pid
}

func forwardSignals() {
    for sig in [SIGTERM, SIGINT, SIGHUP] {
        signal(sig) { s in
            if childGroup > 0 { kill(-childGroup, s) }
        }
    }
}

func main() -> Never {
    let options = parse(Array(CommandLine.arguments.dropFirst()))
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

    var raw: Int32 = 0
    while waitpid(pid, &raw, 0) == -1 {
        if errno != EINTR {
            logger.error("waitpid: \(String(cString: strerror(errno)), privacy: .public)")
            status?.write("exit=125")
            exit(125)
        }
    }
    let sig = raw & 0x7f
    if sig == 0 {
        let code = (raw >> 8) & 0xff
        status?.write("exit=\(code)")
        logger.info("\(path, privacy: .public) pid=\(pid) exit=\(code)")
    } else {
        status?.write("signal=\(sig)")
        logger.info("\(path, privacy: .public) pid=\(pid) signal=\(sig)")
    }
    exit(0)
}

main()
