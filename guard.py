"""mightyCode Guard: heuristic inspection of tool calls produced by the local model.

The proxy runs every tool_use the model emits through check_tool_call() *before* Claude Code
sees it. A non-None return value is a human-readable reason and the call is dropped.

This is a best-effort tripwire, NOT a sandbox: a determined model can evade regexes.
Combine it with Claude Code's permission prompts (do not use bypassPermissions) and, for hard
guarantees, an OS-level egress filter (pf / Little Snitch / Lulu) or a container.
"""
import json
import os
import re
from urllib.parse import urlparse

DEFAULT_ALLOW = (
    "localhost,127.0.0.1,::1,github.com,githubusercontent.com,huggingface.co,hf.co,"
    "pypi.org,pythonhosted.org,npmjs.org,npmjs.com,yarnpkg.com,crates.io,rubygems.org,"
    "golang.org,go.dev,formulae.brew.sh,brew.sh,docs.python.org,developer.mozilla.org,"
    "stackoverflow.com,wikipedia.org"
)
ALLOW = {h.strip().lower() for h in (DEFAULT_ALLOW + "," + os.environ.get("GUARD_ALLOW_HOSTS", "")).split(",") if h.strip()}


def host_allowed(host):
    host = host.lower().strip("[]").rstrip(".")
    return any(host == a or host.endswith("." + a) for a in ALLOW)


URL_RE = re.compile(r"\b(?:https?|ftps?|wss?|sftp|ssh|git|tcp|udp)://(?:[^/\s@'\"]*@)?(\[[0-9a-fA-F:]+\]|[A-Za-z0-9._-]+)", re.I)
SCP_RE = re.compile(r"(?<![\w/])[\w.-]+@([A-Za-z0-9.-]+\.[A-Za-z]{2,}|\d{1,3}(?:\.\d{1,3}){3}):")
HOSTISH_RE = re.compile(r"\b((?:\d{1,3}\.){3}\d{1,3}|(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,})\b")
DEVTCP_RE = re.compile(r"/dev/(?:tcp|udp)/([^/\s]+)/")

NET_VERB = re.compile(
    r"(?<![\w./-])(curl|wget|nc|ncat|netcat|socat|telnet|ssh|scp|sftp|rsync|ftp|tftp|aria2c|httpie|xh|lynx|w3m|"
    r"mail|sendmail|mutt|swaks|openssl\s+s_client|git\s+(?:push|pull|fetch|clone|remote|ls-remote)|"
    r"pip3?|uv|npm|pnpm|yarn|brew|cargo|gem|docker\s+(?:push|pull)|gh|hf|huggingface-cli)\b")
RAW_NET = re.compile(r"(?<![\w./-])(nc|ncat|netcat|socat|telnet|ssh|scp|sftp|rsync|ftp|tftp|swaks|sendmail|mutt|mail)\b")
NET_LIB = re.compile(
    r"\b(requests\.|urllib|http\.client|httpx|aiohttp|socket\.|urlopen|XMLHttpRequest|axios|net\.connect|"
    r"Net::HTTP|open-uri|WebSocket|smtplib|ftplib|paramiko|fetch\s*\(|require\(['\"]https?['\"]\)|"
    r"node:https?|fs\.createReadStream.*pipe)", re.I)
DNS_EXFIL = re.compile(r"(?<![\w./-])(dig|nslookup|host|ping|drill)\b[^\n]*(\$\(|`|\$\{?\w)")

SECRET_PATH = re.compile(
    r"(\.ssh\b|id_(?:rsa|ed25519|ecdsa|dsa)|\.aws\b|\.netrc|\.git-credentials|\.gnupg|\.config/gh\b|\.docker/config|"
    r"\.kube/config|\.npmrc|\.pypirc|Library/Keychains|security\s+(?:find|dump|export)-|/etc/(?:passwd|shadow)|"
    r"(?<![\w])\.env\b|\.claude/|\.anthropic|\.huggingface|huggingface/token|\.bash_history|\.zsh_history|"
    r"Application Support/(?:Google|Firefox|BraveSoftware|Chromium|Microsoft Edge)|"
    r"(?<![\w.])(?:printenv|env)(?:\s|$)|\$\{?[A-Z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL)[A-Z0-9_]*)", re.I)
HARD_SECRET_READ = re.compile(
    r"(\.ssh/|id_(?:rsa|ed25519|ecdsa|dsa)|\.aws/credentials|\.git-credentials|\.netrc|\.gnupg|Library/Keychains|"
    r"security\s+(?:find|dump|export)-)")
READ_VERB = re.compile(r"(?<![\w./-])(cat|less|more|head|tail|cp|base64|xxd|od|hexdump|strings|tar|zip|grep|awk|sed|python3?|open)\b")
SECRET_LITERAL = re.compile(
    r"(AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|sk-ant-[\w-]{20,}|gh[pousr]_[A-Za-z0-9]{30,}|"
    r"hf_[A-Za-z0-9]{30,}|xox[baprs]-[\w-]{10,}|AIza[0-9A-Za-z_-]{35}|[A-Za-z0-9+/]{240,}={0,2})")

PERSIST_PATH = re.compile(
    r"(\.zshrc|\.zprofile|\.zshenv|\.zlogin|\.bashrc|\.bash_profile|\.profile\b|authorized_keys|LaunchAgents|LaunchDaemons|"
    r"\.git/hooks/|\.claude/(?:settings|hooks)|\.ssh/config|/etc/|/Library/(?:LaunchAgents|LaunchDaemons|StartupItems))")
WRITE_OP = re.compile(r"(>>?|\btee\b|\bcp\b|\bmv\b|sed\s+-i|\bln\s+-s|\binstall\b|\bchmod\b)")
REMOTE_EXEC = re.compile(
    r"((curl|wget)[^|;&\n]*\|\s*(sudo\s+)?(ba|z|da)?sh\b|base64\s+(-d|-D|--decode)[^\n]*\|\s*(sudo\s+)?(ba|z)?sh\b|"
    r"eval\s+\"?\$\(\s*(curl|wget)|(ba|z)?sh\s+<\(\s*(curl|wget))")
DESTRUCTIVE = re.compile(
    r"(\brm\s+-[a-zA-Z]*[rR][a-zA-Z]*\s+(?:--no-preserve-root\s+)?(?:/|~|\$HOME|\"\$HOME\")(?:\s|/?\*|$)|\bmkfs\b|"
    r"\bdd\b[^\n]*\bof=/dev/|:\(\)\s*\{|\bsudo\b|\bcrontab\s+(?!-l)|\blaunchctl\s+(?:load|bootstrap|submit)|"
    r"\bdiskutil\s+(?:erase|partition)|\bchmod\s+[0-7]*[4-7][0-7]{3}\b|\bchmod\s+\+s\b)")
SCRIPT_ARG = re.compile(r"(?<![\w])((?:~|/|\./|\.\./)?[\w./~-]+\.(?:py|sh|js|mjs|rb|pl|ts|zsh))\b")


def _hosts_in(text):
    hosts = set()
    for m in URL_RE.finditer(text):
        hosts.add(m.group(1))
    for m in SCP_RE.finditer(text):
        hosts.add(m.group(1))
    for m in DEVTCP_RE.finditer(text):
        hosts.add(m.group(1))
    return hosts


def _bad_hosts(text):
    return sorted(h for h in _hosts_in(text) if not host_allowed(h))


def _expand(path, cwd):
    p = os.path.expanduser(path)
    if not os.path.isabs(p):
        if not cwd:
            return None
        p = os.path.join(cwd, p)
    return p


def analyze_text(text, *, is_command, cwd=None, depth=0):
    """Return a reason string if `text` (a shell command or file content) looks dangerous."""
    has_net = bool(NET_VERB.search(text) or NET_LIB.search(text) or DEVTCP_RE.search(text))
    bad = _bad_hosts(text)

    if is_command:
        if REMOTE_EXEC.search(text):
            return "downloads/decodes code and pipes it straight into a shell (remote code execution)"
        if DESTRUCTIVE.search(text):
            return "destructive or privileged command (rm -rf on a root/home path, sudo, mkfs, dd to a device, crontab/launchctl, setuid)"
        if READ_VERB.search(text) and HARD_SECRET_READ.search(text):
            return "reads credential material (SSH keys, cloud/git credentials, keychain)"
        if PERSIST_PATH.search(text) and WRITE_OP.search(text):
            return "modifies a persistence/startup location (shell rc, authorized_keys, LaunchAgents, git hooks, Claude settings)"
        if DNS_EXFIL.search(text):
            return "DNS lookup with interpolated data (possible DNS exfiltration)"
        if RAW_NET.search(text):
            names = sorted(h for h in set(HOSTISH_RE.findall(text)) if not host_allowed(h)) or ["<unknown host>"]
            if not _hosts_in(text) or bad or any(not host_allowed(n) for n in names if n != "<unknown host>"):
                return f"raw network tool connecting to a non-allowlisted destination ({', '.join(names + bad)[:120]})"
    if has_net:
        if bad:
            return f"network access to non-allowlisted host(s): {', '.join(bad)[:160]}"
        if SECRET_PATH.search(text):
            return "sends/handles secrets (credential files, environment variables, tokens) together with network access"
        if SECRET_LITERAL.search(text):
            return "secret-looking literal (API key / private key / long encoded blob) together with network access"
        if not is_command and PERSIST_PATH.search(text):
            return "script touches persistence locations while using the network"

    if is_command and depth == 0:  # follow scripts the command will run, e.g. `python exfil.py`
        for m in list(SCRIPT_ARG.finditer(text))[:4]:
            path = _expand(m.group(1), cwd)
            if path and os.path.isfile(path) and os.path.getsize(path) < 300_000:
                try:
                    with open(path, errors="replace") as fh:
                        body = fh.read()
                except OSError:
                    continue
                why = analyze_text(body, is_command=False, cwd=cwd, depth=1)
                if why:
                    return f"script `{m.group(1)}` it would run is unsafe: {why}"
    return None


def check_tool_call(name, inp, cwd=None):
    """Return a reason string if the tool call must be blocked, else None."""
    inp = inp if isinstance(inp, dict) else {}
    if name == "Bash":
        return analyze_text(str(inp.get("command", "")), is_command=True, cwd=cwd)
    if name in ("Write", "Edit", "MultiEdit", "NotebookEdit"):
        path = str(inp.get("file_path") or inp.get("notebook_path") or "")
        if PERSIST_PATH.search(path):
            return f"writes to a persistence/system location: {path}"
        body = "\n".join(str(v) for k, v in inp.items() if k in ("content", "new_string", "new_source")) or json.dumps(inp.get("edits", ""))
        return analyze_text(body, is_command=False, cwd=cwd)
    if name == "Read":
        path = str(inp.get("file_path", ""))
        if HARD_SECRET_READ.search(path):
            return f"reads credential material: {path}"
        return None
    if name == "WebFetch":
        url = str(inp.get("url", ""))
        bad = _bad_hosts(url) or ([urlparse(url).hostname] if urlparse(url).hostname and not host_allowed(urlparse(url).hostname) else [])
        if bad:
            return f"WebFetch to non-allowlisted host: {', '.join(bad)}"
        if SECRET_LITERAL.search(url) or SECRET_PATH.search(url):
            return "WebFetch URL carries secret-looking data"
        return None
    if name in ("Glob", "Grep", "WebSearch", "TodoWrite", "Task", "Agent", "ExitPlanMode", "BashOutput", "KillShell"):
        return None
    # MCP / unknown tools: scan every string argument.
    blob = json.dumps(inp, ensure_ascii=False)
    bad = _bad_hosts(blob)
    if bad:
        return f"tool `{name}` references non-allowlisted host(s): {', '.join(bad)[:160]}"
    if SECRET_LITERAL.search(blob):
        return f"tool `{name}` argument contains a secret-looking literal"
    return None


def format_block_message(blocked):
    """blocked: list of (tool_name, input, reason). Message shown to the user inside Claude Code."""
    lines = ["🛑 **mightyCode Guard blocked this step / このステップをブロックしました**", ""]
    for name, inp, reason in blocked:
        arg = inp.get("command") or inp.get("url") or inp.get("file_path") or json.dumps(inp, ensure_ascii=False)
        arg = str(arg).replace("\n", " ⏎ ")
        lines += [f"- Tool: `{name}`", f"- Reason: {reason}", f"- Input: `{arg[:240]}{'…' if len(arg) > 240 else ''}`", ""]
    lines += [
        "The local model tried an action that looks like data exfiltration, credential access, persistence or a destructive command, "
        "so the tool call was **not** passed to Claude Code and nothing was executed. "
        "ローカルモデルが情報送信・認証情報アクセス・永続化・破壊的操作に見える操作を試みたため、実行していません。",
        "",
        "If this was legitimate: allow the host with `GUARD_ALLOW_HOSTS=example.com claude-local`, or run `GUARD=warn claude-local` (log only). "
        "Log: `claude-local guardlog`.",
    ]
    return "\n".join(lines)
