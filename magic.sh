#!/usr/bin/env bash
# magic: run a coding agent locally, but against a remote machine over SSH.
#
# Usage:
#     magic.sh ssh="ssh user@host" agent="claude ..."
#     magic.sh ssh="ssh -p 2222 -i key.pem user@host" agent="codex ..."
#
# The agent runs on the local box. Its shell is redirected to a remote bash over
# SSH, so every command it runs executes on the remote. Native file tools are
# disabled for Claude so that reads/writes also flow through the remote shell.

set -eu

SYSTEM_PROMPT='You are running locally but your Bash tool executes on a REMOTE machine over SSH. The native Read, Write, Edit, Glob, and Grep tools are disabled here because the filesystem you care about is on the remote host — use shell commands instead: cat/head/tail to read, tee/printf/sed to write, rg or grep to search, find for globbing. All paths refer to the remote filesystem. Each Bash call may run in a fresh shell, so put multi-step sequences into a single command with && rather than relying on cd or env vars persisting across calls.'

ssh_spec=""
agent_spec=""
for arg in "$@"; do
  case "$arg" in
    ssh=*)   ssh_spec=${arg#ssh=} ;;
    agent=*) agent_spec=${arg#agent=} ;;
    *)       echo "magic: expected key=value, got '$arg'" >&2; exit 1 ;;
  esac
done

if [ -z "$ssh_spec" ] || [ -z "$agent_spec" ]; then
  echo 'usage: magic ssh="ssh user@host" agent="claude ..."' >&2
  exit 1
fi

ssh_parts=()
eval "ssh_parts=($ssh_spec)"
[ ${#ssh_parts[@]} -gt 0 ] || { echo "magic: ssh argument is empty" >&2; exit 1; }

agent_argv=()
eval "agent_argv=($agent_spec)"
[ ${#agent_argv[@]} -gt 0 ] || { echo "magic: agent argument is empty" >&2; exit 1; }

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/magic-XXXXXXXX")
bindir="$tmpdir/bin"
mkdir -p "$bindir"
control="$tmpdir/ctl"
logfile="$tmpdir/shim.log"

"${ssh_parts[0]}" -M -S "$control" -f -N -o ControlPersist=60 "${ssh_parts[@]:1}"

ssh_base=$(printf '%q ' "${ssh_parts[0]}" -S "$control" -tt -o LogLevel=ERROR "${ssh_parts[@]:1}")
logfile_q=$(printf '%q' "$logfile")

shim="$bindir/bash"
# Unquoted heredoc: $ssh_base/$logfile_q expand here, but every runtime var the
# shim will use ($@, $#, $PPID, $$, $PWD, $MAGIC_DEBUG, ${q[*]}, …) is escaped
# with \$ so it lands in the output literally.
cat > "$shim" <<SHIM
#!/usr/bin/env bash
# magic: forward this shell invocation to a remote bash over SSH.
if [ -n "\$MAGIC_DEBUG" ]; then
  { echo "[\$(date +%T.%N)] pid=\$\$ ppid=\$PPID pwd=\$PWD argc=\$# args=\$(printf '%q ' "\$@")"; } >> $logfile_q 2>&1
fi
if [ \$# -eq 0 ]; then
  exec $ssh_base bash
fi
q=()
for a in "\$@"; do q+=("\$(printf %q "\$a")"); done
exec $ssh_base "bash \${q[*]}"
SHIM
chmod +x "$shim"
ln -s "$shim" "$bindir/sh"

case "$(basename "${agent_argv[0]}")" in
  claude)
    # Claude Code only honors CLAUDE_CODE_SHELL if the path contains "bash" or
    # "zsh"; our shim is named "bash" so it passes. Disable the native file
    # tools so all I/O flows through the shell, and thus through the shim.
    agent_argv+=(--disallowedTools Read Write Edit Glob Grep --append-system-prompt "$SYSTEM_PROMPT")
    export CLAUDE_CODE_SHELL="$shim"
    ;;
esac

echo "magic: tmpdir=$tmpdir" >&2

# Do NOT prepend PATH or override SHELL: unrelated subprocesses would look up
# `bash`/`sh` and find the shim, invoke it with no args, and hang on the
# interactive remote bash branch.
exec "${agent_argv[@]}"
