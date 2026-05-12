#:package System.CommandLine@2.0.0-beta4.22272.1
#:property PublishAot=false
#:property AssemblyName=tli

using System.CommandLine;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

const string DefaultUrl = "http://teams-api.127.0.0.1.sslip.io:30080";

var rootCommand = new RootCommand("Teams CLI — manage engineering teams via the Teams API");

// ─── health ──────────────────────────────────────────────────────────────────
{
    var urlOpt = new Option<string>("--url", () => DefaultUrl, "Teams API base URL");
    var cmd = new Command("health", "Check Teams API health");
    cmd.AddOption(urlOpt);
    cmd.SetHandler(async (string url) =>
    {
        var node = await GetJsonAsync(url, "/health");
        if (node is null) return;
        Console.WriteLine($"Status:      {node["status"]}");
        Console.WriteLine($"Teams count: {node["teams_count"]}");
    }, urlOpt);
    rootCommand.AddCommand(cmd);
}

// ─── create ──────────────────────────────────────────────────────────────────
{
    var nameArg = new Argument<string>("name", "Team name");
    var urlOpt = new Option<string>("--url", () => DefaultUrl, "Teams API base URL");
    var outputOpt = new Option<string>("--output", () => "table", "Output format: table or json");
    var cmd = new Command("create", "Create a new team");
    cmd.AddArgument(nameArg);
    cmd.AddOption(urlOpt);
    cmd.AddOption(outputOpt);
    cmd.SetHandler(async (string name, string url, string output) =>
    {
        using var http = new HttpClient();
        var body = JsonSerializer.Serialize(new { name });
        var response = await http.PostAsync($"{url}/teams",
            new StringContent(body, Encoding.UTF8, "application/json"));
        var json = await response.Content.ReadAsStringAsync();
        if (!response.IsSuccessStatusCode)
        {
            await Console.Error.WriteLineAsync($"Error: {json}");
            Environment.Exit(1);
            return;
        }
        PrintTeam(JsonNode.Parse(json), output);
    }, nameArg, urlOpt, outputOpt);
    rootCommand.AddCommand(cmd);
}

// ─── list ────────────────────────────────────────────────────────────────────
{
    var urlOpt = new Option<string>("--url", () => DefaultUrl, "Teams API base URL");
    var outputOpt = new Option<string>("--output", () => "table", "Output format: table or json");
    var cmd = new Command("list", "List all teams");
    cmd.AddOption(urlOpt);
    cmd.AddOption(outputOpt);
    cmd.SetHandler(async (string url, string output) =>
    {
        var raw = await GetRawAsync(url, "/teams");
        if (raw is null) return;
        if (output == "json") { Console.WriteLine(raw); return; }
        var arr = JsonNode.Parse(raw)?.AsArray();
        if (arr is null || arr.Count == 0) { Console.WriteLine("No teams found."); return; }
        Console.WriteLine($"{"ID",-38}  {"NAME",-30}");
        Console.WriteLine(new string('-', 72));
        foreach (var t in arr)
            Console.WriteLine($"{t?["id"],-38}  {t?["name"],-30}");
    }, urlOpt, outputOpt);
    rootCommand.AddCommand(cmd);
}

// ─── get ─────────────────────────────────────────────────────────────────────
{
    var idArg = new Argument<string>("id", "Team ID");
    var urlOpt = new Option<string>("--url", () => DefaultUrl, "Teams API base URL");
    var outputOpt = new Option<string>("--output", () => "table", "Output format: table or json");
    var cmd = new Command("get", "Get a team by ID");
    cmd.AddArgument(idArg);
    cmd.AddOption(urlOpt);
    cmd.AddOption(outputOpt);
    cmd.SetHandler(async (string id, string url, string output) =>
    {
        var node = await GetJsonAsync(url, $"/teams/{id}");
        if (node is null) return;
        PrintTeam(node, output);
    }, idArg, urlOpt, outputOpt);
    rootCommand.AddCommand(cmd);
}

// ─── delete ──────────────────────────────────────────────────────────────────
{
    var idArg = new Argument<string>("id", "Team ID");
    var urlOpt = new Option<string>("--url", () => DefaultUrl, "Teams API base URL");
    var forceOpt = new Option<bool>("--force", "Skip confirmation prompt");
    var cmd = new Command("delete", "Delete a team by ID");
    cmd.AddArgument(idArg);
    cmd.AddOption(urlOpt);
    cmd.AddOption(forceOpt);
    cmd.SetHandler(async (string id, string url, bool force) =>
    {
        if (!force)
        {
            Console.Write($"Are you sure you want to delete team '{id}'? [y/N]: ");
            var answer = Console.ReadLine();
            if (!string.Equals(answer?.Trim(), "y", StringComparison.OrdinalIgnoreCase))
            {
                Console.WriteLine("Aborted.");
                return;
            }
        }
        using var http = new HttpClient();
        var response = await http.DeleteAsync($"{url}/teams/{id}");
        if (!response.IsSuccessStatusCode)
        {
            var err = await response.Content.ReadAsStringAsync();
            await Console.Error.WriteLineAsync($"Error: {err}");
            Environment.Exit(1);
            return;
        }
        Console.WriteLine($"Team '{id}' deleted.");
    }, idArg, urlOpt, forceOpt);
    rootCommand.AddCommand(cmd);
}

// ─── deploy ──────────────────────────────────────────────────────────────────
{
    var appArg = new Argument<string>("app_name", "Application name");
    var teamOpt = new Option<string>("--team", "Team ID") { IsRequired = true };
    var imageOpt = new Option<string>("--image", "Container image to deploy (e.g. registry.io/checkout:v2)") { IsRequired = true };
    var urlOpt = new Option<string>("--url", () => DefaultUrl, "Teams API base URL");
    var cmd = new Command("deploy", "Deploy an application to a team namespace via Argo Rollouts");
    cmd.AddArgument(appArg);
    cmd.AddOption(teamOpt);
    cmd.AddOption(imageOpt);
    cmd.AddOption(urlOpt);
    cmd.SetHandler(async (string appName, string team, string image, string url) =>
    {
        using var http = new HttpClient();
        var body = JsonSerializer.Serialize(new { app_name = appName, image });
        var response = await http.PostAsync($"{url}/teams/{team}/deploy",
            new StringContent(body, Encoding.UTF8, "application/json"));
        if (!response.IsSuccessStatusCode)
        {
            var err = await response.Content.ReadAsStringAsync();
            await Console.Error.WriteLineAsync($"Error: {err}");
            Environment.Exit(1);
            return;
        }
        Console.WriteLine($"Deploying {appName} → {image}");
        Console.WriteLine("Preview pod is spinning up. Run 'tli promote' when ready.");
    }, appArg, teamOpt, imageOpt, urlOpt);
    rootCommand.AddCommand(cmd);
}

// ─── promote ─────────────────────────────────────────────────────────────────
{
    var appArg = new Argument<string>("app_name", "Application name");
    var teamOpt = new Option<string>("--team", "Team ID") { IsRequired = true };
    var urlOpt = new Option<string>("--url", () => DefaultUrl, "Teams API base URL");
    var cmd = new Command("promote", "Promote a preview revision to active (switch live traffic)");
    cmd.AddArgument(appArg);
    cmd.AddOption(teamOpt);
    cmd.AddOption(urlOpt);
    cmd.SetHandler(async (string appName, string team, string url) =>
    {
        using var http = new HttpClient();
        var body = JsonSerializer.Serialize(new { app_name = appName });
        var response = await http.PostAsync($"{url}/teams/{team}/promote",
            new StringContent(body, Encoding.UTF8, "application/json"));
        if (!response.IsSuccessStatusCode)
        {
            var err = await response.Content.ReadAsStringAsync();
            await Console.Error.WriteLineAsync($"Error: {err}");
            Environment.Exit(1);
            return;
        }
        Console.WriteLine($"Promoting {appName} — switching active traffic to new version.");
    }, appArg, teamOpt, urlOpt);
    rootCommand.AddCommand(cmd);
}

// ─── rollback ────────────────────────────────────────────────────────────────
{
    var appArg = new Argument<string>("app_name", "Application name");
    var teamOpt = new Option<string>("--team", "Team ID") { IsRequired = true };
    var urlOpt = new Option<string>("--url", () => DefaultUrl, "Teams API base URL");
    var cmd = new Command("rollback", "Abort an in-progress rollout; active version stays live");
    cmd.AddArgument(appArg);
    cmd.AddOption(teamOpt);
    cmd.AddOption(urlOpt);
    cmd.SetHandler(async (string appName, string team, string url) =>
    {
        using var http = new HttpClient();
        var body = JsonSerializer.Serialize(new { app_name = appName });
        var response = await http.PostAsync($"{url}/teams/{team}/rollback",
            new StringContent(body, Encoding.UTF8, "application/json"));
        if (!response.IsSuccessStatusCode)
        {
            var err = await response.Content.ReadAsStringAsync();
            await Console.Error.WriteLineAsync($"Error: {err}");
            Environment.Exit(1);
            return;
        }
        Console.WriteLine($"Rolling back {appName} — aborting rollout, active version remains live.");
    }, appArg, teamOpt, urlOpt);
    rootCommand.AddCommand(cmd);
}

return await rootCommand.InvokeAsync(args);

// ─── Helpers ─────────────────────────────────────────────────────────────────

static async Task<string?> GetRawAsync(string baseUrl, string path)
{
    try
    {
        using var http = new HttpClient();
        var response = await http.GetAsync($"{baseUrl}{path}");
        var body = await response.Content.ReadAsStringAsync();
        if (!response.IsSuccessStatusCode)
        {
            await Console.Error.WriteLineAsync($"Error: {body}");
            Environment.Exit(1);
            return null;
        }
        return body;
    }
    catch (HttpRequestException ex)
    {
        await Console.Error.WriteLineAsync($"Connection failed: {ex.Message}");
        Environment.Exit(1);
        return null;
    }
}

static async Task<JsonNode?> GetJsonAsync(string baseUrl, string path)
{
    var raw = await GetRawAsync(baseUrl, path);
    return raw is null ? null : JsonNode.Parse(raw);
}

static void PrintTeam(JsonNode? t, string output)
{
    if (t is null) return;
    if (output == "json")
    {
        Console.WriteLine(t.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
        return;
    }
    Console.WriteLine($"ID:   {t["id"]}");
    Console.WriteLine($"Name: {t["name"]}");
}
