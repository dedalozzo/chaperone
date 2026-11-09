<p align="center">
  <img src="icon/Chaperone-1024.png" alt="Chaperone logo: a shield with a guiding star and a route leading to a terminal" width="200">
</p>

<h1 align="center">Chaperone</h1>

<p align="center">Run a script as the responsible process of a tiny background app, so macOS Developer Tools exempts what it builds from the XProtect first-launch scan.</p>

Chaperone is a tiny macOS app that runs one script as its *responsible process*. Add it to **System Settings > Privacy & Security > Developer Tools**, and every program the script builds and starts skips the XProtect first-launch scan. It has no window, no Dock icon and never shows a prompt.

It was written for a compiler's test gate. The gate builds and starts thousands of fresh binaries, and each first launch from an agent's shell cost 38–39 s of scanning. Through an exempt app the same launch takes 0.010 s.

## The problem

On every first launch of a newly built, unnotarized program, `syspolicyd` queues an XProtect scan. The scan is skipped when the program's **responsible process** is an app listed (and switched on) under Developer Tools. `tccd` makes that check: it is asked for `kTCCServiceDeveloperTool` on behalf of the responsible process.

The responsible process is usually the app that started the chain: a terminal, an IDE. A child inherits it from its parent unless someone *disclaims* responsibility while spawning it. This is where the exemption gets lost:

- **Agent tools and wrappers.** Claude Code's Bash tool breaks the chain: its children lose the host app's exemption ([anthropics/claude-code#104173](https://github.com/anthropics/claude-code/issues/104173)).
- **Terminal multiplexers and session servers.** Sessions run under a daemon launched by `launchd`, so the daemon is the responsible process, not the terminal app you see. If that daemon is not an app, or its Developer Tools entry has gone stale, you pay the scan.
- **`osascript`, `nohup`, `setsid`, detached shells.** None of them starts a new responsible process. They stay in the caller's chain.

Only an app that **LaunchServices** starts (`open -a …`) becomes a fresh responsible process. The [cargo-nextest macOS notes](https://nexte.st/docs/installation/macos/) describe the same mechanism and the usual fix: list your terminal. That works until the chain passes through something that disclaims it, or you don't want a terminal window for a 3-hour background run.

Chaperone is that app, made for the job: `open` starts it, it spawns your script without disclaiming responsibility, waits, writes the exit status and quits. The Developer Tools picker accepts only `.app` bundles, so it is an app. A small command-line shim, `chaperone`, calls `open` for you.

## Install

Chaperone needs macOS 13 or later, on Apple silicon or Intel. Pick one of three ways. MacPorts and the source install build it on your Mac, which needs the Xcode command-line tools (`xcode-select --install`). Building it yourself is the safer choice for a tool that skips malware scans: the source is one Swift file you can read first.

There is no Homebrew formula. I did not include Homebrew because I think it's trash.

| Way | Command | The app to add to Developer Tools |
|---|---|---|
| MacPorts | `sudo port install chaperone` | `/Applications/MacPorts/Chaperone.app` |
| Release zip | see below | `~/Applications/Chaperone.app` |
| From source | `make install` | `~/Applications/Chaperone.app` |

### MacPorts

```sh
sudo port install chaperone
```

Until the port is in the MacPorts tree, use the Portfile in `packaging/macports/` as a local port repository (see `packaging/macports/README.md`). The app goes to `/Applications/MacPorts/Chaperone.app` and the shim to `/opt/local/bin/chaperone`.

### Release zip

Each [GitHub release](https://github.com/dedalozzo/chaperone/releases) has a ready-built `Chaperone-<version>-universal.zip`, for Apple silicon and Intel Macs. The app in it is signed only ad hoc, not by an Apple developer certificate, so macOS quarantines the download and refuses to open it. Clear the quarantine flag yourself, and only if you trust the build:

```sh
cd ~/Downloads
ditto -x -k Chaperone-1.0.1-universal.zip .
xattr -dr com.apple.quarantine Chaperone-1.0.1
mkdir -p ~/Applications ~/.local/bin
ditto Chaperone-1.0.1/Chaperone.app ~/Applications/Chaperone.app
install -m 755 Chaperone-1.0.1/chaperone ~/.local/bin/chaperone
```

The release page lists the zip's SHA-256. Check it with `shasum -a 256 Chaperone-1.0.1-universal.zip` before installing.

### From source

```sh
make install
```

This builds `build/Chaperone.app` for your Mac's architecture (ad-hoc signed, with the Hardened Runtime) and copies it to `~/Applications/Chaperone.app`, and the shim to `~/.local/bin/chaperone`. No sudo. `PREFIX_APP`, `PREFIX_BIN`, `APP_PATH` and `DESTDIR` change where things go, and `ARCH="arm64 x86_64"` builds a universal app (see the `Makefile`).

`make test` runs the test suite first if you want to see it pass on your Mac (see [Tests](#tests)).

### Then, by hand, once

1. Open **System Settings > Privacy & Security > Developer Tools**.
2. Click **+**, pick the app from the table above (press ⇧⌘G in the picker and type the path), and make sure its switch is on.

Then create the allowlist (below). Chaperone refuses everything until it exists.

### Ad-hoc signing: re-add after every rebuild

The app has no signing identity: it is signed ad hoc, so its identity is its code hash. The hash is the same for every build of the same source with the same Xcode, and changes when either changes. **After every upgrade (`port upgrade`, a new release) or a rebuild with a new Xcode, remove Chaperone from Developer Tools and add it again.** Otherwise the old entry no longer matches and every launch is scanned again. Signing with a stable identity (a self-signed certificate, or a free Apple Development certificate) would remove this step.

The bundle identifier is `io.github.dedalozzo.chaperone`. Don't change it.

The first launch of a freshly built Chaperone.app is itself scanned (about 40–50 s here), because nothing exempts the app's own launch. Later launches start at once.

## Usage

```sh
chaperone [--wait] [--clean-env] [--cwd DIR] [--log FILE] [--status FILE] -- /abs/script [args...]
chaperone --version | --help
```

| Option | Meaning |
|---|---|
| `--wait` | Block until the script ends, then exit with its exit code: 128+N if signal N ended it, 126 if Chaperone refused the script, 125 if Chaperone itself failed. |
| `--clean-env` | Don't pass the caller's environment: the script gets LaunchServices' base environment plus `HOME`, `USER`, `LOGNAME`, `TMPDIR` and `PATH=/usr/bin:/bin:/usr/sbin:/sbin`. By default, every exported variable is handed over with one `open --env K=V` each. (On macOS 26.5, `open` also passes its own environment to the app it launches, so `--clean-env` runs `open` under `env -i`.) |
| `--cwd DIR` | The script's working directory. Default: the caller's `$PWD`. |
| `--log FILE` | The script's stdout and stderr are appended here. Default: `run.log` in a new private folder, `$TMPDIR/chaperone-<timestamp>.<random>/`, that only you can open. |
| `--status FILE` | The status file. Default: `run.status` in the same folder. |
| `--version` | Print the version of the app the shim runs, and its path. |

The shim prints `log=<path>` and `status=<path>` on stdout. The script's stdin is `/dev/null`.

Chaperone creates the log and the status file with mode 0600, and refuses either path if it is a symbolic link. If the status file can't be opened, nothing runs.

The status file gets one line per event:

```
app=<pid of the Chaperone instance>
pid=<pid of the script>
exit=<code>          or   signal=<n>
```

A refusal writes `refused=<reason>` followed by `exit=126`. Refusals also go to the unified log:

```sh
/usr/bin/log show --last 1h --predicate 'subsystem == "io.github.dedalozzo.chaperone"'
```

(In zsh, a bare `log` is a builtin: use `/usr/bin/log`.)

Each `chaperone` call starts a separate Chaperone instance (`open -n`), so runs can overlap. Without `--wait` the shim returns at once and the run carries on: it does not depend on the shell that started it. With `--wait` you can still run the shim detached (e.g. in the background of an agent session) and collect the exit code when it ends. Killing the shim never stops the run.

To stop a run, send SIGTERM (or SIGINT, SIGHUP) to the `app=` pid. Chaperone forwards it to the script's process group, then records `signal=<n>`.

The script must be executable and start with a `#!` line. A typical gate script:

```sh
#!/bin/zsh
export LC_ALL=C
cd /abs/path/to/checkout/compiler || exit 1
exec ./ci-check.sh
```

```sh
chaperone --wait --cwd /abs/path/to/checkout -- /abs/path/to/gate-scripts/run-gate.sh
```

## The allowlist

`~/.config/chaperone/allow` lists one absolute path prefix per line. Blank lines and `#` comments are ignored. A missing file means every script is refused.

```
# Chaperone: scripts it may run
/Users/me/tools/gate-scripts
```

Chaperone runs a script only if all of these hold:

- the script's real path (symlinks resolved) is a listed prefix or lies under one (`/a/b` allows `/a/b/x.sh`, not `/a/bc/x.sh`); a prefix of `/` is ignored;
- the script is a regular, executable file owned by you, and neither group- nor world-writable;
- the allowlist file itself is owned by you and neither group- nor world-writable;
- every directory above the script, and above the allowlist, up to `/`, is owned by you or root, and not group- or world-writable unless it has the sticky bit (like `/tmp`). Otherwise someone else could rename a directory and put their own script, or allowlist, in its place;
- macOS lets Chaperone read the script (see [Troubleshooting](#troubleshooting)).

The allowlist is read from your home directory as the user database records it, not from `$HOME`, so a caller's environment can't move it.

## Security model

Listing an app under Developer Tools tells macOS not to malware-scan what that app runs. Chaperone extends that to **every script the allowlist permits, and everything those scripts start**. Here is what it defends, and what it doesn't.

**What it protects against**

- **Other users on the Mac.** They can't get their code run through Chaperone. Every file Chaperone trusts (the allowlist and the script) and every directory above them must be changeable only by you or root. So nobody else can edit them, or swap them for their own, not even between Chaperone's checks and the run.
- **Mistakes.** A missing allowlist refuses everything. A prefix of `/` and relative lines are ignored. Symlinks are resolved before the prefix check, and prefixes match whole path components only.
- **Tampering with the run's files.** By default the log and the status file live in a private folder. Both are created with mode 0600, and a symlink at either path is refused, so nobody can read your build log or point Chaperone's writes at one of your files.
- **Loading code into Chaperone.** The app is signed with the Hardened Runtime, so dyld ignores `DYLD_*` variables, and the environment the shim hands over can't inject a library before the allowlist check. One side effect: scripts don't receive `DYLD_*` variables. Scripts run by macOS's own shells (`#!/bin/zsh`, `#!/bin/bash`, `#!/usr/bin/env …`) never did, because those shells drop them too.
- **Moving the allowlist.** The allowlist is read from your home directory as the user database records it, not from `$HOME`.

**What it does not protect against**

- **Code already running as you.** It can edit the allowlist, or put a script in an allowed folder, and then call `chaperone`. The allowlist keeps other users and mistakes out; it is no barrier against malware already running as you. Listing Chaperone is the same trust as listing Terminal: anything that runs through it is unscanned.
- **What your scripts run.** An allowed script runs everything it starts unscanned, including tools found through `PATH` and the rest of the caller's environment, which passes through unchanged. Gate scripts should set what they rely on, or be called with `--clean-env`.
- **The build you install.** The release zip is signed ad hoc, not notarized: you trust whoever built it. MacPorts and `make install` build from source on your Mac.

**Keep the allowlist narrow.** List a directory of scripts you wrote and that only you can change, not a whole checkout, `~`, or a downloads folder.

## Troubleshooting

**Refused: "macOS does not let Chaperone read the script".** macOS protects some folders (Documents, Desktop, Downloads, iCloud Drive, removable and network volumes) per app. Chaperone is the responsible process of its scripts, so it needs that access itself, whatever your terminal has. macOS can also withdraw it later. Allow Chaperone under **System Settings > Privacy & Security > Files & Folders** (or **Full Disk Access**), or keep the scripts somewhere else. A script that is allowed but then works in a protected folder (a checkout under `~/Documents`) needs the same access: there, the failure shows up inside the script, as "Operation not permitted" in the log.

**Refused: "… is inside DIR, which is group- or world-writable".** Someone other than you could replace what is in `DIR`. Run `chmod go-w DIR`, or move the scripts.

**Every launch is scanned again after an upgrade.** The new build has a new code hash: remove Chaperone from Developer Tools and add it again.

**The reason for any refusal** is in the status file (`refused=` line) and in the unified log:

```sh
/usr/bin/log show --last 1h --predicate 'subsystem == "io.github.dedalozzo.chaperone"'
```

## How to verify

You need a probe that prints its responsible process, built under a **new name** each time (a name that has been launched once is not scanned again):

```c
// resp.c
#include <stdio.h>
#include <libproc.h>
#include <unistd.h>
extern pid_t responsibility_get_pid_responsible_for_pid(pid_t);
int main(void) {
  pid_t r = responsibility_get_pid_responsible_for_pid(getpid());
  char p[PROC_PIDPATHINFO_MAXSIZE] = "?";
  proc_pidpath(r, p, sizeof p);
  printf("responsible=%d %s\n", r, p);
  return 0;
}
```

An allowed script that builds and times it:

```sh
#!/bin/zsh
n=/abs/allowed/probes/p-$(date +%s)-$$
cc -o $n /abs/allowed/resp.c
s=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
$n
e=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
echo "first launch: $(( e - s )) s"
```

```sh
chaperone --wait --log /tmp/probe.log -- /abs/allowed/probe.sh; cat /tmp/probe.log
```

1. **Attribution.** The probe prints `responsible=… /Users/you/Applications/Chaperone.app/Contents/MacOS/chaperone-app`. Before the app is in Developer Tools, the first launch is scanned (tens of seconds), and the log shows tccd asking about the app.

   On macOS 26.5, tccd logs it like this (older releases print `Handling access request to kTCCServiceDeveloperTool … responsible_path=… Auth Right: Unknown`):

   ```
   tccd … AUTHREQ_CTX: … service=kTCCServiceDeveloperTool, preflight=yes, query=1 …
   tccd … AUTHREQ_ATTRIBUTION: … accessing={TCCDProcess: identifier=io.github.dedalozzo.chaperone, … binary_path=…/Chaperone.app/Contents/MacOS/chaperone-app}, requesting={… identifier=com.apple.syspolicyd …}
   tccd … Service kTCCServiceDeveloperTool does not allow prompting; returning denied.
   ```

   To see them, search for the service name rather than the app (the query and the attribution are separate lines):

   ```sh
   /usr/bin/log show --last 5m --predicate 'process == "tccd"' | grep -E 'kTCCServiceDeveloperTool|dedalozzo.chaperone'
   ```

2. **Exemption.** After you add the app, a fresh probe's first launch takes about 10 ms (measured here: 0.010–0.013 s), and syspolicyd logs no scan for that binary: no `queueing up scan for code`, no `GK performScan`, and no `evaluateScanResult` naming it.

   ```sh
   /usr/bin/log show --last 5m --predicate 'process == "syspolicyd"' | grep -E 'p-<name>|queueing up scan'
   ```

   On macOS 26.5, syspolicyd still asks tccd once per Chaperone instance, but now the answer is "allowed" (`authValue=2`, `authReason=4` = set in System Settings). Before the app was listed, it was `authValue=0`, `authReason=5`, followed by `returning denied`:

   ```
   tccd … AUTHREQ_CTX: msgID=484.233, … service=kTCCServiceDeveloperTool, preflight=yes, query=1 …
   tccd … AUTHREQ_ATTRIBUTION: msgID=484.233, attribution={accessing={TCCDProcess: identifier=io.github.dedalozzo.chaperone, …}, requesting={… com.apple.syspolicyd …}}
   tccd … AUTHREQ_RESULT: msgID=484.233, authValue=2, authReason=4, …
   ```

   Match the `AUTHREQ_RESULT` to its query by `msgID`.

## Tests

```sh
make test
```

`test/run.sh` runs a test build of the app directly, without `open`. That build is compiled with `-D CHAPERONE_TESTING`, which makes it read its allowlist from `$CHAPERONE_TEST_ALLOWLIST`. So the tests never touch your allowlist, and need neither Developer Tools nor a launch through LaunchServices. They cover:
- the allowlist rules and every refusal;
- arguments, stdin, the working directory and the log;
- the status file, including mode 0600 and symlinks refused;
- signal forwarding to the whole process group;
- the shim's option handling.

They also check that the real build is signed with the Hardened Runtime and has no trace of the test hook. The responsible process and the skipped scan can only be seen in a real launch: check those by hand, as described in [How to verify](#how-to-verify).

## Uninstall

| Way | Command |
|---|---|
| MacPorts | `sudo port uninstall chaperone` |
| Release zip | `rm -rf ~/Applications/Chaperone.app ~/.local/bin/chaperone` |
| From source | `make uninstall` (removes `~/Applications/Chaperone.app` and `~/.local/bin/chaperone`) |

Then remove Chaperone from Developer Tools, and delete `~/.config/chaperone` if you no longer need the allowlist.

## Repository layout

| Path | What it is |
|---|---|
| `src/main.swift` | The app: argument parsing, allowlist checks, spawning the script, the status file. |
| `chaperone` | The command-line shim: builds the `open` call, hands over the environment, implements `--wait`. |
| `Info.plist` | Bundle metadata: bundle id `io.github.dedalozzo.chaperone`, `LSBackgroundOnly`, the icon, the text macOS shows when it asks for folder access. |
| `Makefile` | `make`, `make test`, `make install`, `make uninstall`, `make dist` (the release zip), `make clean`. |
| `test/run.sh` | The test suite (`make test`). |
| `icon/` | The app icon: `Chaperone.svg` (vector source), `Chaperone-1024.png`, `Chaperone.iconset/`, `Chaperone.icns` (bundled into the app), and `build-icon.sh` with its two Swift helpers to regenerate them (see `icon/README.md`). |
| `media/` | `linkedin-1200x627.png`, the social image for posts (1.91:1, shown uncropped in the LinkedIn feed), and `build-linkedin.swift`, which renders it (`swift media/build-linkedin.swift` from the repo root). |
| `packaging/` | The MacPorts Portfile (`packaging/macports/`) and the release checklist (`packaging/README.md`). |

## License

MIT. See `LICENSE`.
