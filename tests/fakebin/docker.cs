// Stand-in for docker.exe used by tests/Test-Devtools.ps1 on Windows. It is compiled on the
// fly (Windows PowerShell's Add-Type) because the module looks for a real docker.exe.
// Same contract as the shell script tests/fakebin/docker used on Linux and macOS:
// record the arguments, one per line, to $DOCKER_ARGS_FILE and exit with $DOCKER_FORCE_EXIT.
using System;
using System.IO;

public static class FakeDocker
{
    public static int Main(string[] args)
    {
        string file = Environment.GetEnvironmentVariable("DOCKER_ARGS_FILE");
        if (string.IsNullOrEmpty(file))
        {
            file = Path.Combine(Path.GetTempPath(), "docker_args.txt");
        }

        string text = "";
        foreach (string a in args)
        {
            text += a + "\n";
        }
        File.WriteAllText(file, text);

        int code;
        if (!int.TryParse(Environment.GetEnvironmentVariable("DOCKER_FORCE_EXIT"), out code))
        {
            code = 0;
        }
        return code;
    }
}
