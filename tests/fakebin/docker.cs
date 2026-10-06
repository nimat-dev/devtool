// Stand-in for docker.exe used by the PowerShell tests on Windows. It is compiled on the fly
// (Windows PowerShell's Add-Type) because the module and setup.ps1 look for a real docker.exe.
// Same contract as the shell script tests/fakebin/docker used on Linux and macOS; see the
// comment at the top of that file for the environment variables.
using System;
using System.IO;

public static class FakeDocker
{
    static int Code(string name, int fallback)
    {
        int value;
        if (int.TryParse(Environment.GetEnvironmentVariable(name), out value))
        {
            return value;
        }
        return fallback;
    }

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

        string log = Environment.GetEnvironmentVariable("DOCKER_LOG_FILE");
        if (!string.IsNullOrEmpty(log))
        {
            File.AppendAllText(log, string.Join(" ", args) + "\n");
        }

        string failOn = Environment.GetEnvironmentVariable("DOCKER_FAIL_ON");
        if (!string.IsNullOrEmpty(failOn))
        {
            foreach (string a in args)
            {
                if (a == failOn)
                {
                    return 1;
                }
            }
        }

        string first = args.Length > 0 ? args[0] : "";
        string second = args.Length > 1 ? args[1] : "";

        if (first == "version")
        {
            string server = Environment.GetEnvironmentVariable("DOCKER_SERVER");
            Console.WriteLine(string.IsNullOrEmpty(server) ? "linux/99.0.0-fake" : server);
            return Code("DOCKER_VERSION_EXIT", 0);
        }
        if (first == "compose" && second == "version")
        {
            Console.WriteLine("Docker Compose version v99-fake");
            return Code("DOCKER_COMPOSE_EXIT", 0);
        }
        if ((first == "compose" && second == "build") || first == "build")
        {
            return Code("DOCKER_BUILD_EXIT", 0);
        }
        if (first == "image")
        {
            return Code("DOCKER_IMAGE_EXIT", 0);
        }
        if (first == "run" && !string.IsNullOrEmpty(Environment.GetEnvironmentVariable("DOCKER_FAKE_OUTPUT")))
        {
            Console.WriteLine("fake docker run ok");
        }
        return Code("DOCKER_FORCE_EXIT", 0);
    }
}
