# magic

<table>
  <tr>
    <td>
      <img src="https://github.com/user-attachments/assets/f0f49790-8a87-4d81-957c-621572346761" />
    </td>
    <td width="250">
      <video src="https://github.com/user-attachments/assets/550ff2f6-34a7-4135-adc3-2a114be9c0a0" controls></video>
    </td>
  </tr>
</table>

Your remote machine has restricted internet and you can't install your favorite agentic coder on it? Just run the agent locally and let it work against the remote over SSH, the same way you would yourself.

## Run it

Directly from GitHub, nothing to install:

```
bash <(curl -sL https://raw.githubusercontent.com/MahammadNuriyev62/magic/main/magic.sh) \
  ssh="ssh user@host" \
  agent="claude"
```

Or clone and run:

```
./magic.sh ssh="ssh user@host" agent="claude"
./magic.sh ssh="ssh -p 2222 -i ~/.ssh/key.pem ubuntu@1.2.3.4" agent="claude --model sonnet"
```

Where:

* `ssh=` is the full SSH command you'd normally type to reach the box.
* `agent=` is the agent you'd normally launch locally.

Needs `bash`, `ssh`, and whichever agent you're launching.

## How it works

1. Opens a persistent SSH master so every forwarded call reuses one handshake.
2. Writes a tiny bash shim that rewrites every `bash -c <cmd>` into `ssh -S <socket> <host> "bash <cmd>"`. The `-S <socket>` is what makes it reuse the master from step 1 instead of opening a fresh connection.
3. Points the agent's shell at that shim via `CLAUDE_CODE_SHELL`.
4. Disables the agent's native file tools (Read/Write/Edit/Glob/Grep for Claude), so all file I/O also flows through the shell, which routes to the remote.

The agent sees a filesystem, runs commands, reads files, and has no idea any of it is on a different box.

Set `MAGIC_DEBUG=1` to log every forwarded call to `/tmp/magic-*/shim.log`.

## Limitations

Tested with Claude Code and GitHub Copilot CLI (`copilot`). For Copilot, magic prepends the shim dir to PATH (its shell hook), writes a small custom agent file to `~/.copilot/agents/magic-remote.agent.md` that whitelists only shell-family tools and sets `includeEnvironmentContext: false` to stop Copilot answering environment questions from its own process context, then launches Copilot with `--agent magic-remote`. The shim uses `ssh -tt` to preserve pty mode, which Copilot's persistent `bash --norc --noprofile` session needs.

Codex and other agentic coders are on the roadmap. If you try one and it works (or breaks in an interesting way), open an issue.

## Caveats

* `cd` doesn't persist across the agent's Bash calls. That's the agent's own behavior, not magic's. Chain multi-step work with `&&` in one call.
* `magic.sh` uses bash `eval` to split the `ssh=` and `agent=` strings, so variables and subshells in those strings will expand. You control the input, so just don't paste things you don't understand.
* The tmpdir is not cleaned up on exit. The SSH master self-expires 60 seconds after the last call, but that's fine: if the agent goes idle longer than that, the next call just opens a fresh ssh connection (a bit slower, still works).
