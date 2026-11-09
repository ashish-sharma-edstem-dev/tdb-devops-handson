#!/usr/bin/env python3
"""PreToolUse guard for AI coding agents.

Runs before every Bash / Read / Edit / Write tool call an agent makes in this repo.
It is the second line of defence after the permission rules in .claude/settings.json:
permission rules match command prefixes, this inspects the whole command
(chained commands, flags in any position, pipes).

Contract (Claude Code hooks): JSON on stdin, exit 0 = allow,
exit 2 = block, and stderr is shown to the agent as the reason.
Standard library only, so it runs anywhere python3 exists.
"""

from __future__ import annotations

import json
import re
import shlex
import subprocess
import sys
from dataclasses import dataclass
from pathlib import PurePath


@dataclass(frozen=True)
class Rule:
    pattern: re.Pattern[str]
    reason: str


def _rx(expr: str) -> re.Pattern[str]:
    return re.compile(expr, re.IGNORECASE)


# Each rule is matched against every single command in a chain (split on ; && || |).
COMMAND_RULES: tuple[Rule, ...] = (
    # Infrastructure: plan/validate only. Never change real infrastructure or state.
    Rule(
        _rx(
            r"^(terraform|tofu|terragrunt)\b.*\b(apply|destroy|import|taint|untaint|force-unlock)\b"
        ),
        "terraform apply/destroy/import/taint/force-unlock is never run by an agent",
    ),
    Rule(
        _rx(r"^(terraform|tofu)\b.*\bstate\s+(rm|mv|push|replace-provider)\b"),
        "terraform state changes are human-only",
    ),
    Rule(
        _rx(r"^aws\b(?!.*\b(sts\s+get-caller-identity)\b)(?!\s+\S+\s+(describe|list|get)-)"),
        "aws CLI is read-only for agents (describe-/list-/get- only)",
    ),
    # Git: everything reaches main through a reviewed PR.
    Rule(
        _rx(r"^git\b.*\bpush\b.*(\s-f\b|--force\b|--force-with-lease\b|--mirror\b|\s\+\S)"),
        "force-push rewrites shared history",
    ),
    Rule(
        _rx(r"^git\b.*\bpush\b.*(\s|:)(main|master)(\s|$)"),
        "direct push to main is not allowed; open a PR",
    ),
    Rule(_rx(r"^git\b.*\bcommit\b.*(--no-verify|\s-n\b)"), "skipping commit hooks is not allowed"),
    Rule(_rx(r"^git\b.*\bconfig\b.*\buser\.(name|email)\b\s+\S"), "commit identity is fixed"),
    Rule(
        _rx(r"^git\b.*\b(reset\s+--hard|clean\s+-\w*f)"), "destructive git clean-up needs a human"
    ),
    # GitHub: no bypassing review, no destructive repo operations.
    Rule(_rx(r"^gh\b.*\bpr\s+merge\b.*--admin\b"), "merging with --admin bypasses branch rules"),
    Rule(_rx(r"^gh\b.*\brepo\s+(delete|archive|rename|edit)\b"), "repo settings are human-only"),
    Rule(_rx(r"^gh\b.*\b(secret|variable)\s+(set|delete)\b"), "CI secrets are human-only"),
    Rule(_rx(r"^gh\b.*\bapi\b.*(-X|--method)\s*(DELETE|PUT)\b"), "destructive GitHub API call"),
    # Kubernetes: write operations only against a local kind cluster.
    Rule(
        _rx(r"^(kubectl|helm)\b.*--(kube-)?context[ =](?!kind-)\S+"),
        "kubectl/helm may only target local kind-* contexts",
    ),
    # Host safety.
    Rule(_rx(r"^(sudo|su|doas)\b"), "no privilege escalation"),
    Rule(
        _rx(r"^rm\b.*\s-\w*r\w*f?\w*\s+(/|~|\$HOME|\.\.?)(\s|/?$)"),
        "recursive delete of / ~ . or ..",
    ),
    Rule(
        _rx(r"^docker\b.*\s(--privileged|-v\s*/:|--volume[ =]/:|--pid[ =]host)"),
        "privileged container",
    ),
    Rule(_rx(r"^(chmod|chown)\b.*\s-R\b.*\s/(\s|$)"), "recursive permission change on /"),
)

# A downloaded script piped straight into a shell or interpreter.
PIPE_TO_SHELL = _rx(
    r"\b(curl|wget)\b[^|]*\|\s*(sudo\s+)?(ba|z|da|k)?sh\b|\b(curl|wget)\b[^|]*\|\s*python"
)

# Files that hold credentials. Agents never read or write them.
SECRET_PATHS: tuple[re.Pattern[str], ...] = (
    _rx(r"(^|/)\.env$"),
    _rx(r"(^|/)\.env\.(?!example$)[^/]+$"),
    _rx(r"\.tfstate(\.backup)?$"),
    _rx(r"(^|/)terraform\.tfvars$"),
    _rx(r"\.auto\.tfvars$"),
    _rx(r"(^|/)\.aws/(credentials|config)$"),
    _rx(r"(^|/)\.kube/config$"),
    _rx(r"(^|/)\.ssh/"),
    _rx(r"(^|/)\.docker/config\.json$"),
    _rx(r"\.(pem|key|p12|pfx)$"),
    _rx(r"(^|/)id_(rsa|ed25519|ecdsa)"),
)

# Commands that print file contents. Used to stop `cat .env` style reads via Bash.
READERS = _rx(r"^(cat|less|more|head|tail|bat|nl|strings|xxd|od|grep|rg|sed|awk|cp|scp|base64)\b")

SPLIT = re.compile(r"\s*(?:&&|\|\||;|\||\n)\s*")


def is_secret_path(path: str) -> bool:
    clean = str(PurePath(path))
    return any(p.search(clean) for p in SECRET_PATHS)


def _strip_wrappers(cmd: str) -> str:
    """Drop leading env assignments and harmless wrappers so `FOO=1 time git push` matches `git`."""
    cmd = cmd.strip().lstrip("(").strip()
    cmd = re.sub(r"^(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)+", "", cmd)
    cmd = re.sub(r"^(?:command|builtin|exec|time|nohup|env(?:\s+-\S+)*)\s+", "", cmd)
    cmd = re.sub(r"^(?:\S*/)?(?=(git|terraform|tofu|kubectl|helm|aws|gh|docker|rm)\b)", "", cmd)
    return cmd


def _current_kube_context() -> str:
    try:
        out = subprocess.run(
            ["kubectl", "config", "current-context"],  # noqa: S607
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    return out.stdout.strip()


KUBE_WRITE = _rx(
    r"^(kubectl\b.*\b(apply|create|delete|replace|patch|edit|scale|drain|cordon|rollout\s+restart|set)\b"
    r"|helm\b.*\b(install|upgrade|uninstall|rollback|delete)\b)"
)


def check_command(command: str, kube_context: str | None = None) -> str | None:
    """Return a block reason, or None if the command is allowed."""
    if PIPE_TO_SHELL.search(command):
        return "piping a downloaded script into a shell or interpreter"

    for raw in SPLIT.split(command):
        part = _strip_wrappers(raw)
        if not part:
            continue
        for rule in COMMAND_RULES:
            if rule.pattern.search(part):
                return rule.reason
        if READERS.search(part):
            try:
                tokens = shlex.split(part)
            except ValueError:
                tokens = part.split()
            if any(is_secret_path(tok) for tok in tokens[1:] if not tok.startswith("-")):
                return "reading a credentials file"
        if KUBE_WRITE.search(part) and "--context" not in part and "--kube-context" not in part:
            ctx = kube_context if kube_context is not None else _current_kube_context()
            if not ctx.startswith("kind-"):
                return (
                    f"kubectl/helm writes only to local kind-* clusters (current: {ctx or 'none'})"
                )
    return None


def check(event: dict[str, object]) -> str | None:
    tool = event.get("tool_name")
    tool_input = event.get("tool_input")
    if not isinstance(tool_input, dict):
        return None
    if tool == "Bash":
        command = tool_input.get("command")
        return check_command(command) if isinstance(command, str) else None
    if tool in {"Read", "Edit", "Write", "MultiEdit", "NotebookEdit"}:
        path = tool_input.get("file_path") or tool_input.get("notebook_path")
        if isinstance(path, str) and is_secret_path(path):
            return f"{tool} of a credentials file ({path})"
    return None


def main() -> int:
    try:
        event = json.load(sys.stdin)
    except json.JSONDecodeError:
        # Fail closed: a malformed event is not silently allowed.
        print("agent-guard: could not parse hook input; blocking", file=sys.stderr)
        return 2
    reason = check(event)
    if reason:
        print(f"agent-guard: blocked: {reason}. See AGENTS.md > Agent safety.", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
