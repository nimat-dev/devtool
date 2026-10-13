#!/usr/bin/env python3
"""Drive an interactive shell through a pseudo terminal, like a person typing, and check what it shows.

    tests/pty_shell_test.py SHELL [--full | --tools az,kubectl,helm] -- COMMAND...
    tests/pty_shell_test.py pwsh [--module Devtools.psm1] -- pwsh -NoLogo
    tests/pty_shell_test.py hostbash [--script devtools.sh] -- bash

SHELL is zsh or bash (it only picks the checks). COMMAND starts that shell, for example

    tests/pty_shell_test.py zsh --full -- docker run --rm -it devtools:ci zsh
    tests/pty_shell_test.py bash -- docker run --rm -it devtools:ci bash

--full adds the checks that need the real kubectl, helm and az (the image has them; a laptop
test of the rc files alone does not), --tools picks some of them.

pwsh starts an interactive PowerShell 7 whose profile imports Devtools.psm1, with a fake docker
on the PATH, and checks what a person would see: the Tab menu, Tab completion through the
container, grey history suggestions, the double dash, and the keys being handed back when the
module is removed. (Windows PowerShell 5.1 has no pseudo terminal to drive here.)

hostbash starts an interactive bash that loads devtools.sh from its startup file, with a fake docker
on the PATH, and checks what a person would see: the tools are functions, Tab completion through the
container (also through a shortcut), the Up arrow searching the history, the terminal being handed to
docker (-t), the double dash, and the keys being handed back by devtools-unload. DEVTOOLS_NO_READLINE=1
is checked in a second session. A third session plays Git Bash in the mintty window (OSTYPE=msys,
TERM_PROGRAM=mintty) with a winpty that rewrites path arguments the way Git for Windows' does
(tests/fakebin/winpty): docker must still get -w /work and the rest as typed.

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
        """Ask the shell to exit and wait for it. Killing a `docker run -it` client does not stop
        the container, so give it time to end by itself before falling back to the kill."""
        try:
            # Ctrl-C first and on its own: the terminal throws away input that is still waiting
            # when it turns a Ctrl-C into SIGINT, which is how an "exit" typed right behind it
            # got lost in bash.
            self.send("\x03")
            self.pump(0.5)
            self.send("\x15exit\r")
            end = time.time() + 20
            while time.time() < end and self.proc.poll() is None:
                self.pump(0.2)
        finally:
            if self.proc.poll() is None:
                try:
                    self.proc.kill()
                except OSError:
                    pass
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
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


# A docker that answers the Tab-completion question the way devtools-complete would, plays devtools-ca
# (fetch prints the file DOCKER_CA_FETCH_FILE, check says ok), and writes the arguments of every other
# call to a file.
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
  if [ "${args[$i]}" = devtools-ca ]; then
    case "${args[$((i + 1))]}" in
      fetch) cat "$DOCKER_CA_FETCH_FILE"; echo "fake devtools-ca fetch" >&2; exit 0 ;;
      check) echo "ok: fake check"; exit 0 ;;
    esac
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
            "DEVTOOLS_CERTS": os.path.join(work, "certs"),
            "DOCKER_CA_FETCH_FILE": os.path.join(here, "fixtures", "ca-fetch.pem"),
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

    # --- Add-DevToolsCA shows the certificates and asks before it trusts anything --------------------------------
    certs = env["DEVTOOLS_CERTS"]
    ask = r"Trust 2 certificate\(s\) like this inside the toolbox\? \(y/N\): "
    t.mark()
    t.send("Add-DevToolsCA\r")
    check("Add-DevToolsCA shows what the network signs with and asks first", t.expect(ask, 20, clean=True), tail(t.buf))
    t.mark()
    t.send("n\r")
    check("answering n changes nothing", t.expect(r"Nothing was changed\.", 10, clean=True) and not os.path.exists(certs), tail(t.buf))
    t.pump(0.5)
    t.mark()
    t.send("Add-DevToolsCA\r")
    check("asked again", t.expect(ask, 20, clean=True), tail(t.buf))
    t.mark()
    t.send("y\r")
    check("answering y saves the certificates", t.expect(r"Saved [^\n]*example-corp-root-ca-95e7cda0\.crt", 10, clean=True), tail(t.buf))
    check("and runs the check", t.expect(r"Nothing has to be rebuilt", 10, clean=True), tail(t.buf))
    check("the file is there", os.path.exists(os.path.join(certs, "example-corp-root-ca-95e7cda0.crt")))
    shutil.rmtree(certs, ignore_errors=True)       # the later sessions and checks run without a certificate
    t.pump(0.5)

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


def run_hostbash(options, command):
    here = os.path.dirname(os.path.abspath(__file__))
    script = os.path.join(os.path.dirname(here), "devtools.sh")
    for i, o in enumerate(options):
        if o == "--script" and i + 1 < len(options):
            script = os.path.abspath(options[i + 1])

    work = tempfile.mkdtemp(prefix="devtools-pty-")
    try:
        home = os.path.join(work, "home")
        os.makedirs(home)
        bindir = os.path.join(work, "bin")
        os.makedirs(bindir)
        docker = os.path.join(bindir, "docker")
        with open(docker, "w") as f:
            f.write(FAKE_DOCKER)
        os.chmod(docker, 0o755)
        args_file = os.path.join(work, "docker-args.txt")
        # What a person's ~/.bashrc has: the one line setup.sh adds. The Ctrl-X binding is the test's
        # own: it prints the line being edited, so the checks do not have to read it back from a
        # redrawn screen.
        rc = os.path.join(work, "bashrc")
        with open(rc, "w") as f:
            f.write("PS1='HB> '\n")
            f.write("HISTFILE='%s'\n" % os.path.join(work, "history"))
            f.write("export DEVTOOLS_BASH_ALIASES='%s'\n" % os.path.join(work, "no-aliases.sh"))
            f.write(". '%s'\n" % script)
            f.write("bind -x '\"\\C-x\":printf \"BUF[%s]\\n\" \"$READLINE_LINE\"'\n")

        env = dict(os.environ)
        for name in ("DOCKER_RUN_FILE", "DEVTOOLS_NO_READLINE", "DEVTOOLS_IMAGE", "DEVTOOLS_VOLUME", "TERM_PROGRAM", "AKS_RG", "AKS_NAME"):
            env.pop(name, None)
        env.update({
            "HOME": home,
            "PATH": bindir + os.pathsep + env.get("PATH", ""),
            "TERM": "xterm-256color",
            "INPUTRC": os.path.join(work, "inputrc"),        # none: readline's own defaults
            "DOCKER_ARGS_FILE": args_file,
            "DEVTOOLS_CERTS": os.path.join(work, "certs"),
            "DOCKER_CA_FETCH_FILE": os.path.join(here, "fixtures", "ca-fetch.pem"),
        })
        open(env["INPUTRC"], "w").close()
        bash = command + ["--noprofile", "--rcfile", rc, "-i"]
        if hostbash_checks(bash, env, args_file):
            # DEVTOOLS_NO_READLINE=1 leaves the arrow keys alone.
            env["DEVTOOLS_NO_READLINE"] = "1"
            hostbash_noreadline(bash, env)
            env.pop("DEVTOOLS_NO_READLINE")
            # Git Bash in the mintty window, pretended.
            winpty = os.path.join(bindir, "winpty")
            shutil.copy(os.path.join(here, "fakebin", "winpty"), winpty)
            os.chmod(winpty, 0o755)
            rc_mintty = os.path.join(work, "bashrc-mintty")
            with open(rc) as f:
                text = f.read()
            with open(rc_mintty, "w") as f:
                f.write(text.replace(". '%s'\n" % script, "OSTYPE=msys\n. '%s'\n" % script))
            winpty_log = os.path.join(work, "winpty.log")
            env["TERM_PROGRAM"] = "mintty"
            env["WINPTY_LOG_FILE"] = winpty_log
            hostbash_mintty(command + ["--noprofile", "--rcfile", rc_mintty, "-i"], env, args_file, winpty_log)
        print()
        print("ALL SHELL CHECKS PASSED" if failures == 0 else "%d SHELL CHECK(S) FAILED" % failures)
        return 0 if failures == 0 else 1
    finally:
        shutil.rmtree(work, ignore_errors=True)


def hostbash_checks(command, env, args_file):
    t = Term(command, env=env)
    ready = t.expect(r"HB> ", timeout=30)
    check("bash starts and shows a prompt", ready, tail(t.buf))
    if not ready:
        t.close()
        return False
    t.pump(1.0)

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

    def last_args():
        got = []
        if os.path.exists(args_file):
            with open(args_file) as f:
                got = f.read().split("\n")
        while got and got[-1] == "":
            got.pop()
        return got

    run("type -t az", r"function\r?\n", "az is a function (it shadows an installed az)")
    run("type -t kgp", r"alias\r?\n", "the shortcut kgp is an alias")
    run("bind -p | grep -F '\\e[A\"'", r"history-search-backward", "the Up arrow searches the history")
    run("bind -v | grep show-all", r"show-all-if-ambiguous on", "Tab lists the choices on the first press")

    # --- Tab completion through the container (the fake docker plays the container) ---------------------------
    t.mark()
    t.send("kubectl get po\t")
    t.pump(1.5)
    line_is(r"kubectl get pods ?", "Tab completes kubectl through the container")
    t.mark()
    t.send("kgp --all-nam\t")
    t.pump(1.5)
    line_is(r"kgp --all-namespaces ?", "Tab completes the flags of a shortcut (kgp stands for kubectl get pods)")
    t.mark()
    t.send("terraform ap\t")
    t.pump(1.5)
    line_is(r"terraform apply ?", "Tab completes terraform")

    # --- history search on the arrow keys ---------------------------------------------------------------------
    if os.path.exists(args_file):
        os.remove(args_file)
    run("kgp -n kube-system", r"HB> ", "a shortcut runs from the prompt")
    want = ["devtools:latest", "kubectl", "get", "pods", "-n", "kube-system"]
    check("and reaches the container as kubectl get pods -n kube-system", last_args()[-len(want):] == want, repr(last_args()))
    run("tfp -var x=1", r"HB> ", "another command, to have a history")
    t.mark()
    t.send("kgp -n ku\x1b[A")
    t.pump(0.5)
    line_is(r"kgp -n kube-system", "the Up arrow finds the earlier command that starts with what you typed")
    t.mark()
    t.send("tf\x1b[A")
    t.pump(0.5)
    line_is(r"tfp -var x=1", "and the one that starts with tf")
    t.mark()
    t.send("\x1b[A\x1b[A")
    t.pump(0.5)
    t.send("\x1b[B")
    t.pump(0.5)
    line_is(r"kgp -n kube-system|tfp -var x=1", "the Down arrow goes back toward the newer ones")

    # --- the terminal is handed to docker ---------------------------------------------------------------------
    if os.path.exists(args_file):
        os.remove(args_file)
    t.mark()
    t.send("az account show\r")
    t.pump(1.5)
    got = last_args()
    check("at a terminal docker gets -t (an interactive az login can work)", got[:4] == ["run", "--rm", "-i", "-t"], repr(got))

    # --- the double dash ----------------------------------------------------------------------------------------
    if os.path.exists(args_file):
        os.remove(args_file)
    t.mark()
    t.send("kex my-pod -- ls -la\r")
    t.pump(1.5)
    want = ["devtools:latest", "kubectl", "exec", "-it", "my-pod", "--", "ls", "-la"]
    check("kex pod -- ls -la reaches the container with the double dash", last_args()[-len(want):] == want, repr(last_args()))

    # --- devtools-add-ca shows the certificates and asks before it trusts anything -------------------------------
    certs = env["DEVTOOLS_CERTS"]
    ask = r"Trust 2 certificate\(s\) like this inside the toolbox\? \(y/N\) "
    t.mark()
    t.send("devtools-add-ca\r")
    check("devtools-add-ca shows what the network signs with and asks first", t.expect(ask, 20, clean=True), tail(t.buf))
    t.mark()
    t.send("n\r")
    check("answering n changes nothing", t.expect(r"Nothing was changed\.", 10, clean=True) and not os.path.exists(certs), tail(t.buf))
    t.pump(0.5)
    t.mark()
    t.send("devtools-add-ca\r")
    check("asked again", t.expect(ask, 20, clean=True), tail(t.buf))
    t.mark()
    t.send("y\r")
    check("answering y saves the certificates", t.expect(r"Saved [^\n]*example-corp-root-ca-95e7cda0\.crt", 10, clean=True), tail(t.buf))
    check("and runs the check", t.expect(r"Nothing has to be rebuilt", 10, clean=True), tail(t.buf))
    check("the file is there", os.path.exists(os.path.join(certs, "example-corp-root-ca-95e7cda0.crt")))
    shutil.rmtree(certs, ignore_errors=True)       # the later sessions and checks run without a certificate
    t.pump(0.5)

    # --- the keys are handed back ---------------------------------------------------------------------------------
    run("devtools-unload", r"HB> ", "devtools-unload works")
    run("type -t az || echo gone", r"gone\r?\n", "after it az is no longer a function")
    run("bind -p | grep -F '\\e[A\"'", r"previous-history", "and the Up arrow is the plain history again")
    run("bind -v | grep show-all", r"show-all-if-ambiguous off", "and Tab is as it was")

    t.close()
    return True


def hostbash_noreadline(command, env):
    t = Term(command, env=env)
    ready = t.expect(r"HB> ", timeout=30)
    check("DEVTOOLS_NO_READLINE=1: bash starts", ready, tail(t.buf))
    if ready:
        t.pump(1.0)
        t.mark()
        t.send("bind -p | grep -F '\\e[A\"'\r")
        check("DEVTOOLS_NO_READLINE=1: the Up arrow is left alone", t.expect(r"previous-history", 10, clean=True), tail(t.buf))
        t.pump(0.5)
        t.mark()
        t.send("type -t az\r")
        check("DEVTOOLS_NO_READLINE=1: the tools are still functions", t.expect(r"function", 10, clean=True), tail(t.buf))
    t.close()


def hostbash_mintty(command, env, args_file, winpty_log):
    """Git Bash in the mintty window, pretended: OSTYPE=msys, TERM_PROGRAM=mintty, a real terminal,
    and a winpty that rewrites path arguments the way Git for Windows' winpty does. Without the
    hex hand-over, -w /work arrives as -w C:/fake-git/work, which is the error Git Bash showed."""
    t = Term(command, env=env)
    ready = t.expect(r"HB> ", timeout=30)
    check("mintty: bash starts and shows a prompt", ready, tail(t.buf))
    if not ready:
        t.close()
        return
    t.pump(1.0)

    def read_args():
        got = []
        if os.path.exists(args_file):
            with open(args_file) as f:
                got = f.read().split("\n")
        while got and got[-1] == "":
            got.pop()
        return got

    def run(line, name):
        if os.path.exists(args_file):
            os.remove(args_file)
        t.mark()
        t.send(line + "\r")
        ok = t.expect(r"HB> ", 20, clean=True)
        t.pump(0.5)
        check(name + " (the prompt comes back)", ok, tail(t.buf))
        return read_args()

    got = run("kubectx", "mintty: kubectx")
    check("mintty: docker gets a terminal (-t) and the image defaults", got[:6] == ["run", "--rm", "-i", "-t", "-v", "devtools-home:/root"], repr(got))
    check("mintty: the working directory is /work, not a rewritten path", got[-4:] == ["-w", "/work", "devtools:latest", "kubectx"], repr(got))
    check("mintty: the folder is mounted on /work as is", len(got) > 7 and got[6] == "-v" and got[7].endswith(":/work") and "fake-git" not in got[7], repr(got))
    log = open(winpty_log).read() if os.path.exists(winpty_log) else ""
    check("mintty: docker went through winpty, to the helper script", "devtools-pty-run.sh" in log, repr(log[-300:]))
    check("mintty: winpty was not shown the docker arguments", " -w " not in log and "run --rm" not in log, repr(log[-300:]))

    got = run("kubectl exec -it my-pod -- /bin/sh /no/such/file", "mintty: kubectl exec with paths")
    want = ["devtools:latest", "kubectl", "exec", "-it", "my-pod", "--", "/bin/sh", "/no/such/file"]
    check("mintty: arguments that look like paths arrive as typed", got[-len(want):] == want, repr(got))

    t.mark()
    t.send("devtools-info\r")
    check("mintty: devtools-info says docker goes through winpty", t.expect(r"Terminal\s+winpty", 10, clean=True), tail(t.buf))
    t.pump(0.5)
    t.close()


def main(argv):
    if "--" not in argv or len(argv) < 3:
        print(__doc__)
        return 2
    shell = argv[0]
    options = argv[:argv.index("--")]
    command = argv[argv.index("--") + 1:]
    if shell == "pwsh":
        return run_pwsh(options, command)
    if shell == "hostbash":
        return run_hostbash(options, command)
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
