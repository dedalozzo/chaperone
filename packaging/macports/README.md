# MacPorts port

`sysutils/chaperone/Portfile` builds Chaperone from the GitHub tag tarball. The app goes to `/Applications/MacPorts/Chaperone.app` and the shim to `/opt/local/bin/chaperone`.

Until the port is in the MacPorts tree, use this folder as a local port repository:

```sh
git clone https://github.com/dedalozzo/chaperone.git ~/src/chaperone
cd ~/src/chaperone/packaging/macports
portindex
```

Don't clone into `~/Documents`, `~/Desktop` or `~/Downloads`: MacPorts reads the Portfile as its own `macports` user, which can't enter those private folders, and the install fails with "Permission denied".

Add the folder to `/opt/local/etc/macports/sources.conf`, **above** the `rsync://` line:

```
file:///Users/<you>/src/chaperone/packaging/macports
```

Then:

```sh
sudo port install chaperone
port notes chaperone
```

Run `portindex` again in this folder after every `git pull` that changes the Portfile.

To remove it: `sudo port uninstall chaperone`, and delete the `file://` line from `sources.conf`.

## Checking the Portfile

```sh
cd sysutils/chaperone
port lint --nitpick "file://$PWD"
```
