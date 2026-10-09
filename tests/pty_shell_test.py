#!/usr/bin/env python3
"""Drive an interactive shell through a pseudo terminal, like a person typing, and check what it shows.

    tests/pty_shell_test.py SHELL [--full | --tools az,kubectl,helm] -- COMMAND...
    tests/pty_shell_test.py pwsh [--module Devtools.psm1] -- pwsh -NoLogo

SHELL is zsh or bash (it only picks the checks). COMMAND starts that shell, for example

    tests/pty_shell_test.py zsh --full -- docker run --rm -it devtools:ci zsh
    tests/pty_shell_test.py bash -- docker run --rm -it devtools:ci bash

--full adds the checks that need the real kubectl, helm and az (the image has them; a laptop
test of the rc files alone does not), --tools picks some of them.

pwsh starts an interactive PowerShell 7 whose profile imports Devtools.psm1, with a fake docker
on the PATH, and checks what a person would see: the Tab menu, Tab completion through the
container, grey history suggestions, the double dash, and the keys being handed back when the
module is removed. (Windows PowerShell 5.1 has no pseudo terminal to drive here.)

Prints PASS/FAIL lines and exits 1 on any FAIL.
"""
import fcntl
import os
import pty
import re
import select
import struct
import shutil
import subprocess
import sys
import tempfile
import termios
import time

ESC = "\x1b"
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07|\x1b[=>]")


class Term:
    def __init__(self, command, env=None):
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 200, 0, 0))
        e = dict(os.environ if env is None else env)
        # The colour the grey suggestion is drawn in depends on the terminal type, so pin one.
        e["TERM"] = "xterm-256color"
        self.proc = subprocess.Popen(
            command, stdin=slave, stdout=slave, stderr=slave, env=e,
            start_new_session=True, close_fds=True,
        )
        os.close(slave)
        self.fd = master
        self.buf = ""      # everything received since the last mark()
        self.all = ""

    def pump(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            r, _, _ = select.select([self.fd], [], [], 0.1)
            if r:
                try:
                    data = os.read(self.fd, 65536)
                except OSError:
                    return False
                if not data:
                    return False
                text = data.decode("latin-1")
                self.buf += text
                self.all += text
                if "\x1b[6n" in text:
                    self.answer_cursor_query()
        return True

    def answer_cursor_query(self):
        """PowerShell (PSReadLine, .NET) asks the terminal where the cursor is and waits for the
        answer, as a real terminal gives it. Reply with the position implied by what was printed."""
        visible = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07|\x1b[=>]", "", self.all)
        lines = visible.replace("\r\n", "\n").split("\n")
        row = min(len(lines), 40)
        col = len(lines[-1].split("\r")[-1]) + 1
        os.write(self.fd, ("\x1b[%d;%dR" % (row, col)).encode("ascii"))

    def send(self, text):
        os.write(self.fd, text.encode("latin-1"))

    def mark(self):
        self.buf = ""

    def expect(self, pattern, timeout=15.0, clean=False):
        """Wait until the regex shows up in the output received since mark(); True if it did.
        clean=True matches against the text with the terminal escape sequences taken out."""
        rx = re.compile(pattern, re.S)

        def seen():
            return bool(rx.search(ANSI.sub("", self.buf) if clean else self.buf))

        end = time.time() + timeout
        while time.time() < end:
            if seen():
                return True
            if not self.pump(0.2):
                return seen()
        return seen()

    def close(self):
        try:
            self.send("\x03\x15exit\r")
            self.pump(0.5)
        finally:
            try:
                self.proc.kill()
            except OSError:
                pass
            os.close(self.fd)


failures = 0


def check(name, ok, detail=""):
    global failures
    if ok:
        print("PASS  " + name)
    else:
        print("FAIL  " + name)
        if detail:
            print("      " + detail)
        failures += 1


def tail(text, n=300):
    return repr(re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", text)[-n:])


# A docker that answers the Tab-completion question the way devtools-complete would, and writes the
# arguments of every other call to a file.
FAKE_DOCKER = r"""#!/usr/bin/env bash
args=("$@")
for i in "${!args[@]}"; do
  if [ "${args[$i]}" = devtools-complete ]; then
    tool=${args[$((i + 1))]}
    line=${args[$((i + 2))]}
    case "$tool:$line" in
      kubectl:*"get po")             echo pods ;;
      kubectl:*"--all-nam")          echo "--all-namespaces" ;;
      terraform:*" ap")              echo apply ;;
    esac
    exit 0
  fi
done
printf '%s\n' "$@" > "$DOCKER_ARGS_FILE"
exit 0
"""


def run_pwsh(options, command):
    here = os.path.dirname(os.path.abspath(__file__))
    module = os.path.join(os.path.dirname(here), "Devtools.psm1")
    for i, o in enumerate(options):
        if o == "--module" and i + 1 < len(options):
            module = os.path.abspath(options[i + 1])

    work = tempfile.mkdtemp(prefix="devtools-pty-")
    try:
        home = os.path.join(work, "home")
        os.makedirs(os.path.join(home, ".config", "powershell"))
        bindir = os.path.join(work, "bin")
        os.makedirs(bindir)
        docker = os.path.join(bindir, "docker")
        with open(docker, "w") as f:
            f.write(FAKE_DOCKER)
        os.chmod(docker, 0o755)
        args_file = os.path.join(work, "docker-args.txt")
        # What a person's profile has: the one Import-Module line setup.ps1 adds. The Ctrl-X
        # handler is the test's own: it prints the line being edited, so the checks do not have to
        # read it back from a redrawn screen.
        with open(os.path.join(home, ".config", "powershell", "profile.ps1"), "w") as f:
            f.write("$env:DEVTOOLS_ALIASES = '%s'\n" % os.path.join(work, "no-aliases.ps1"))
            f.write("Import-Module '%s' -Force\n" % module)
            f.write("Set-PSReadLineKeyHandler -Chord 'Ctrl+x' -ScriptBlock {\n")
            f.write("    $line = $null; $cursor = $null\n")
            f.write("    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)\n")
            f.write("    [Console]::Out.Write(\"`nBUF[$line]`n\")\n")
            f.write("}\n")

        env = dict(os.environ)
        for name in ("XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "DOCKER_RUN_FILE"):
            env.pop(name, None)
        env.update({
            "HOME": home,
            "PATH": bindir + os.pathsep + env.get("PATH", ""),
            "TERM": "xterm-256color",
            "DOCKER_ARGS_FILE": args_file,
            "POWERSHELL_UPDATECHECK": "Off",        # no "a new version is available" notice, no network
            "POWERSHELL_TELEMETRY_OPTOUT": "1",
        })
        return pwsh_checks(command, env, module, args_file)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def pwsh_checks(command, env, module, args_file):
    t = Term(command, env=env)
    ready = t.expect(r"PS [^\n]*> ", timeout=60)
    check("pwsh starts and shows a prompt", ready, tail(t.buf))
    if not ready:
        t.close()
        return 1
    t.pump(1.5)

    def run(line, pattern, name, timeout=15):
        t.mark()
        t.send(line + "\r")
        check(name, t.expect(pattern, timeout, clean=True), tail(t.buf))
        t.pump(0.5)

    def line_is(expected, name, timeout=20):
        ok = False
        deadline = time.time() + timeout
        while time.time() < deadline and not ok:
            t.mark()
            t.send("\x18")                      # Ctrl-X prints the line being edited
            ok = t.expect(r"BUF\[" + expected + r"\]", 3)
        check(name, ok, tail(t.buf))
        t.send("\x15")                          # Ctrl-U clears the line, and any menu
        t.pump(0.5)

    run("(Get-Command kgp).CommandType", r"Function\r?\n", "the profile's Import-Module line loaded the shortcuts")
    run("(Get-PSReadLineKeyHandler -Bound | Where-Object Key -eq Tab).Function", r"MenuComplete\r?\n",
        "importing from the profile turned Tab into a menu")

    # --- grey suggestions from the history ---------------------------------------------------------------
    run("kgp -n kube-system", r"PS [^\n]*> ", "a shortcut runs from the prompt")
    t.pump(1.0)
    t.mark()
    t.send("kgp -n ku")
    check("a grey suggestion from the history shows as you type", t.expect(r"be-system", 10), tail(t.buf))
    t.send("\x15")
    t.pump(0.5)

    # --- Tab completion through the container (the fake docker plays the container) ---------------------------
    t.mark()
    t.send("kubectl get po\t")
    t.pump(1.0)
    line_is(r"kubectl get pods ?", "Tab completes kubectl through the container")
    t.mark()
    t.send("kgp --all-nam\t")
    t.pump(1.0)
    line_is(r"kgp --all-namespaces ?", "Tab completes the flags of a shortcut (kgp stands for kubectl get pods)")
    t.mark()
    t.send("terraform ap\t")
    t.pump(1.0)
    line_is(r"terraform apply ?", "Tab completes terraform")

    # --- the double dash ----------------------------------------------------------------------------------
    if os.path.exists(args_file):
        os.remove(args_file)
    t.mark()
    t.send("kex my-pod -- ls -la\r")
    t.pump(1.5)
    got = []
    if os.path.exists(args_file):
        with open(args_file) as f:
            got = f.read().split("\n")
    while got and got[-1] == "":
        got.pop()
    want = ["devtools:latest", "kubectl", "exec", "-it", "my-pod", "--", "ls", "-la"]
    check("kex pod -- ls -la reaches the container with the double dash", got[-len(want):] == want, repr(got))

    # --- the keys are handed back --------------------------------------------------------------------------
    run("Remove-Module Devtools", r"PS [^\n]*> ", "Remove-Module works")
    run("(Get-PSReadLineKeyHandler -Bound | Where-Object Key -eq Tab).Function", r"(?<![A-Za-z])Complete\r?\n",
        "removing the module gives Tab its old meaning back")
    run("Import-Module '%s' -Force" % module, r"PS [^\n]*> ", "importing it again works")
    run("(Get-PSReadLineKeyHandler -Bound | Where-Object Key -eq Tab).Function", r"MenuComplete\r?\n",
        "and turns the menu on again")

    t.close()
    print()
    print("ALL SHELL CHECKS PASSED" if failures == 0 else "%d SHELL CHECK(S) FAILED" % failures)
    return 0 if failures == 0 else 1


def main(argv):
    if "--" not in argv or len(argv) < 4:
        print(__doc__)
        return 2
    shell = argv[0]
    options = argv[:argv.index("--")]
    command = argv[argv.index("--") + 1:]
    if shell == "pwsh":
        return run_pwsh(options, command)
    tools = set()
    if "--full" in options:
        tools = {"kubectl", "helm", "az"}
    for i, o in enumerate(options):
        if o == "--tools" and i + 1 < len(options):
            tools |= set(options[i + 1].split(","))

    t = Term(command)
    prompt = r"toolbox.*[#%] " if shell == "zsh" else r"[#$] "
    ready = t.expect(prompt, timeout=60)
    check(shell + " starts and shows a prompt", ready, tail(t.buf))
    if not ready:
        t.close()
        return 1
    t.pump(1.0)

    # --- aliases ------------------------------------------------------------------------------
    t.mark()
    t.send("alias kgp\r")
    check("alias kgp is defined", t.expect(r"kubectl get pods", 10), tail(t.buf))
    t.pump(0.5)
    t.mark()
    t.send("type aksx\r")
    check("the AKS helper aksx is defined", t.expect(r"aksx is (a )?(shell )?function", 10), tail(t.buf))
    t.pump(0.5)

    # --- history: kept, and (zsh) suggested as you type ----------------------------------------
    t.mark()
    t.send(": zq-marker-9137\r")
    t.pump(1.0)
    t.mark()
    t.send(": zq-m")
    if shell == "zsh":
        shown = t.expect(ESC + r"\[38;5;244m[^\n]*arker-9137", 10)
        check("zsh suggests the earlier command in grey as you type", shown, tail(t.buf))
    else:
        t.send("\x1b[A")      # bash: the up arrow brings back the last line
        check("bash keeps history (up arrow brings the last line back)", t.expect(r"zq-marker-9137", 10), tail(t.buf))
    t.send("\x15")           # Ctrl-U clears the line
    t.pump(0.5)

    # --- colours (zsh) ------------------------------------------------------------------------------
    if shell == "zsh":
        t.mark()
        t.send("echo")
        check("zsh colours a command that exists", t.expect(ESC + r"\[32m", 10), tail(t.buf))
        t.send("\x15")
        t.pump(0.5)

    # --- Tab completion -------------------------------------------------------------------------------
    # The screen is redrawn with cursor movements while you type, so the raw output is not a good
    # place to read the result from. Ctrl-X prints the line the shell is holding instead.
    t.mark()
    if shell == "zsh":
        t.send('dumpbuf() { print -r -- "BUF[${BUFFER}]" }; zle -N dumpbuf; bindkey "^X" dumpbuf\r')
    else:
        t.send('bind -x \'"\\C-x":printf "BUF[%s]\\n" "$READLINE_LINE"\'\r')
    t.pump(1.0)

    def complete(typed, expected, name, timeout=20):
        t.mark()
        t.send(typed + "\t")
        t.pump(1.5)
        deadline = time.time() + timeout
        ok = False
        while time.time() < deadline and not ok:
            t.mark()
            t.send("\x18")                      # Ctrl-X: print the current line
            ok = t.expect(r"BUF\[" + expected + r"\]", 3)
        check(name, ok, tail(t.buf))
        t.send("\x15")                          # clear the line, and any menu
        t.pump(0.5)

    complete("flux boo", r"flux bootstrap ?", "Tab completes flux (a Cobra tool)")
    complete("gh pr li", r"gh pr list ?", "Tab completes gh")
    complete("terraform ap", r"terraform apply ?", "Tab completes terraform")
    complete("tf ap", r"tf apply ?", "Tab completes terraform through the alias tf")
    if "kubectl" in tools:
        complete("kubectl cre", r"kubectl create ?", "Tab completes kubectl")
        complete("k cre", r"k create ?", "Tab completes kubectl through the alias k")
        complete("kgp --all-nam", r"kgp --all-namespaces ?", "Tab completes flags through the alias kgp")
    if "helm" in tools:
        complete("helm ins", r"helm install ?", "Tab completes helm")
    if "az" in tools:
        complete("az acc", r"az account ?", "Tab completes az", timeout=60)
        complete("azsubs --refr", r"azsubs --refresh ?", "Tab completes flags through the alias azsubs", timeout=60)

    t.close()
    print()
    print("ALL SHELL CHECKS PASSED" if failures == 0 else "%d SHELL CHECK(S) FAILED" % failures)
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
