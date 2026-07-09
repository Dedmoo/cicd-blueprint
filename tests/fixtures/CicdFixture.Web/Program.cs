var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

var version = Environment.GetEnvironmentVariable("DEPLOY_VERSION") ?? "1";

app.MapGet("/health", () => Results.Json(new { status = "ok", version }));
app.MapGet("/", () => Results.Text($"CicdFixture v{version}", "text/plain"));

app.Run();
