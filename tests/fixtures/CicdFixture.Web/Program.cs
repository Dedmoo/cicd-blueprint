using CicdFixture.Data;
using Microsoft.EntityFrameworkCore;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddDbContext<AppDbContext>(options =>
{
    var connectionString = builder.Configuration.GetConnectionString("DefaultConnection")
        ?? "Data Source=cicd-fixture.db";
    options.UseSqlite(connectionString);
});

var app = builder.Build();

var version = Environment.GetEnvironmentVariable("DEPLOY_VERSION") ?? "1";

app.MapGet("/health", () => Results.Json(new { status = "ok", version }));
app.MapGet("/", () => Results.Text($"CicdFixture v{version}", "text/plain"));

app.Run();
