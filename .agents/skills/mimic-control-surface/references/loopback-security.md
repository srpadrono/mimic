# The loopback boundary and the discovery file

**Never widen the control plane's binding** beyond `127.0.0.1`. It must stay unreachable from
whatever the app under test can route to.

The discovery file is the other half of that boundary, and it is a credential: it is written
`0600` by setting the mode on a temporary file and then `rename(2)`-ing it into place. Do not
reach for `Data.write(options: .atomic)` and a following `chmod` — `.atomic` renames, so the token
sits at the final path at the umask default until the `chmod` lands, and stays there if it throws.
Resolution reads `port` from that file and derives the host; it does not read `baseURL`, because a
file that can name the host can send the token off-box.

**A discovered token goes to the instance that advertised it, and nowhere else.** Destination and
credential are now resolved together in `ControlClient.discover`: the token from `control.json` is
attached only when the URL's *host* is loopback (`127.0.0.1`, `::1`, `[::1]`, `localhost`) **and**
its port is the one that file advertised — `ControlEndpointDiscovery.namesDiscoveredInstance`.
They used to be resolved independently, so `mimic state --url http://attacker.example` posted this
machine's live control-plane credential to that host in an `X-Mimic-Token` header. A caller
legitimately reaching Mimic through a forwarded port or a container supplies the credential
itself with `MIMIC_CONTROL_TOKEN`, which still wins — that is the caller naming a token rather
than the CLI guessing one.

**`mimic app stop` confirms before it signals.** It asks the instance the discovery file names for
`.state` on that file's own port and requires the reported pid to match, because a file left by a
crashed process can name a pid the system has since reused. It ignores `--url` for the same
reason — a pid only means something on the machine the file was read from. Two things this
forecloses, both deliberate: a *wedged* instance, and one whose file carries no token, can no
longer be stopped by `mimic app stop`; the refusal names the pid and prints `kill <pid>`.

**`MIMIC_CONTROL_FILE` relocates the discovery file** for a run that must not touch the shared
one. Both sides honour it through one function — the read half is `ControlEndpointDiscovery` in
`Domain`, which the CLI resolves through and whose `overrideURL` the write side
(`ControlEndpointFile.writeURL` in `ControlPlane`) delegates to — the override *replaces* the
search list rather than joining the front of it, and the parent directory is created `0700` on
that path too: an isolated run is not a less sensitive one. The reader used to be implemented
twice, and the copies drifted in both directions (the override only on the app's side, the
token-pairing hardening only on the CLI's); `Domain` is the one home the module-edge gate allows
both to share, so keep it there.
