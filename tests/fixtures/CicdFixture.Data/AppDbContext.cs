using Microsoft.EntityFrameworkCore;

namespace CicdFixture.Data;

public class AppDbContext(DbContextOptions<AppDbContext> options) : DbContext(options)
{
    public DbSet<MarkerRow> Markers => Set<MarkerRow>();
}

public class MarkerRow
{
    public int Id { get; set; }

    public string Name { get; set; } = string.Empty;
}
