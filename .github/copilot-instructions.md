# ProxyPAN: DarkPAN Proxy & Cache for Perl/CPAN

## Architecture Overview

This is a **Mojolicious plugin** that creates a transparent CPAN proxy with local caching and DarkPAN hosting capabilities. It intercepts `cpanm` (cpanminus) requests, serves locally cached distributions, and proxies missing packages from CPAN.

**Core Components:**
- **`proxypan`**: Mojolicious::Lite app entry point that loads the ProxyPAN plugin
- **`lib/Mojolicious/Plugin/ProxyPAN.pm`**: Main plugin orchestrator
- **`lib/Mojolicious/Plugin/ProxyPAN/Routes.pm`**: HTTP route handlers with intelligent request routing
- **`lib/Mojolicious/Plugin/ProxyPAN/Helpers.pm`**: Mojolicious helpers for file operations, SQLite DB, package management
- **`lib/Mojolicious/Plugin/ProxyPAN/Hooks.pm`**: Request lifecycle hooks (auth extraction, logging)
- **`lib/Mojo/ProxyPAN/Distribution.pm`**: Distribution object model (module/version/filename)
- **`lib/Mojo/ProxyPAN/Util.pm`**: Tarball analysis utilities (META parsing, lib scanning)

**Data Flow:**
1. `cpanm` → ProxyPAN (via conditional routes based on User-Agent)
2. Check local cache in `authors/id/` directory structure
3. If missing → proxy to CPAN, cache downloaded tarball, extract package metadata
4. SQLite DB tracks packages table (module, version, filename)

## Key Conventions

### Modern Perl Signatures
All subs use **postfix signatures**: `sub register ($self, $app, $config) { ... }`
- No prototype-style `@_` unpacking
- Method context: `($self, ...)` or `($c, ...)` for controller actions

### Mojolicious Patterns
- **Helpers** defined via `$app->helper('name' => \&sub)` in `Helpers.pm`
- **Route conditions** like `requires(agent => qr/cpanminus/, proxypan => 0)` differentiate client types
- **`$c->render_later`** for async responses in proxied routes
- **`X-DarkPan: 1` header** prevents infinite proxy loops when forwarding requests

### File Handling
- **`Mojo::File`** objects everywhere (`path()`, `child()`, `slurp()`, `spurt()`)
- **`tempdir`/`tempfile`** for archive extraction
- **Relative paths** calculated via `$_->to_rel($e)` when searching cache directories

### Route Naming & Organization
Routes split by client behavior:
- **`/modules/02packages.details.txt.gz`**: Merged local + CPAN package index (gzipped)
- **`/authors/id/*filename`**: Distribution downloads (cache-or-fetch)
- **`/v1.0/history/:module`**: cpanmetadb module history lookup
- **`/pause/authenquery`**: PAUSE upload endpoint (intercepts multipart form uploads)

### Environment Variables as Config
Prefer `$ENV{VARIABLE}` over hardcoded defaults:
- `DARKPAN_PATH`: colon-separated paths for distribution storage (like `authors/id:/other/path`)
- `SQLITE_DB`: path to SQLite database file
- `CPAN_URL`, `METADB_URL`, `PAUSE_URL`: upstream proxy targets

### Database Schema
Single table in `__DATA__ @@ migrations` section:
```sql
CREATE TABLE packages (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  module TEXT,
  version TEXT,
  filename TEXT UNIQUE
);
```

## Development Workflow

### Running the App
```bash
# Development mode (auto-reload with morbo)
morbo proxypan

# Production mode
hypnotoad proxypan

# With custom environment
DARKPAN_PATH=authors/id SQLITE_DB=proxypan.db perl proxypan daemon
```

### Testing Routes
```bash
# Simulate cpanm request
curl -A cpanminus http://localhost:3000/modules/02packages.details.txt.gz | gunzip

# Download distribution
curl -A cpanminus http://localhost:3000/authors/id/M/MY/MYUSER/MyDist-1.23.tar.gz

# Check module history
curl -A cpanminus http://localhost:3000/v1.0/history/Mojolicious
```

### Adding Distributions to DarkPAN
The `mcpani` (CPAN::Mini::Inject) workflow from README:
```bash
export MCPANI_CONFIG=/data/darkpan/mcpani.conf
mcpani --add --module My::App --authorid SADAMS --modversion 0.01 --file My-App-0.01.tar.gz
mcpani --inject --mirror
```

Or via PAUSE-compatible upload (if implemented):
```bash
curl -u user:pass -F pause99_add_uri_httpupload=@MyDist-1.23.tar.gz http://localhost:3000/pause/authenquery
```

## Critical Implementation Details

### Package Metadata Extraction (`Mojo::ProxyPAN::Util`)
When tarballs are uploaded/cached, extract module info via:
1. **`read_provides($root)`**: Parse META.json/META.yml for declared provides
2. **`scan_lib($root)`**: Use `Module::Metadata` to scan `lib/**/*.pm` for packages
3. **`merge_provides()`**: META takes precedence, then add scanned packages
4. **`to_collection()`**: Convert to `Mojo::Collection` of `Distribution` objects

### Conditional Routing Strategy
- **Non-cpanm clients** (`!cpanminus` user agent): Mock responses to avoid breaking IDE tools
- **cpanm with `X-DarkPan: 1`**: Already proxied, forward directly to avoid loops
- **cpanm without header**: Check cache → proxy to CPAN if missing

### Caching Mechanism in `_download`
```perl
$tx->on(connection => sub ($tx, $connection) {
  my $res = Mojo::Message::Response->new;
  Mojo::IOLoop->stream($connection)->on(read => sub ($stream, $bytes) {
    $res->parse($bytes);
    $c->proxypan->save_file($res->content, $filename) if $res->is_finished;
  });
});
```
Saves downloaded tarballs to `authors/id/` while streaming to client.

### Perlbrew Multi-Version Support
The `perlbrew` directory contains local library installations:
- `perlbrew/libs/perl-5.42.0@default/` structure
- `perlbrew exec --with perl-5.40.0@default` runs commands in specific Perl environment
- Systemd service template (`mojo@.service`) uses `PERLBREW_ROOT=/data/perlbrew`

## Common Tasks

### Add a New Route Handler
1. Add route definition in `Routes.pm` `register()` method
2. Create handler sub (prefix with `_` by convention): `sub _my_handler ($c) { ... }`
3. Use `$c->render_later` if proxying or async
4. Access helpers via `$c->proxypan->paths`, `$c->sql->db`, etc.

### Modify Package Index Generation
See `_reply_packages()` in `Helpers.pm`:
- Queries `packages` table via `$c->proxypan->packages`
- Merges with upstream CPAN's gzipped index if available
- Returns gzipped response with `application/x-gzip` content-type

### Add New Helper
In `Helpers.pm` `register()`:
```perl
$app->helper('my_helper' => sub ($c, @args) { ... });
```
Then use as `$c->my_helper(...)` in routes.

### Database Migrations
Add new migration in `__DATA__ @@ migrations` section:
```sql
-- 2 up
ALTER TABLE packages ADD COLUMN author TEXT;
-- 2 down
-- (SQLite doesn't support DROP COLUMN easily)
```
Auto-runs on plugin load via `$app->sql->migrations->from_data(...)->migrate`.

## Testing

### Test Structure
Follow Mojolicious testing conventions with `Test::Mojo`:
```perl
use Test::More;
use Test::Mojo;
use FindBin;
BEGIN { unshift @INC, "$FindBin::Bin/../lib" }

my $t = Test::Mojo->new('proxypan');

# Test route behavior
$t->get_ok('/modules/02packages.details.txt.gz')
  ->status_is(200)
  ->header_is('Content-Type' => 'application/x-gzip');

done_testing();
```

### Testing Patterns for ProxyPAN

**Route Tests**: Test both cpanm and non-cpanm user agents:
```perl
# Test cpanm behavior
$t->get_ok('/authors/id/A/AU/AUTHOR/Dist-1.0.tar.gz' => {'User-Agent' => 'cpanminus'})
  ->status_is(200);

# Test mock behavior for non-cpanm clients
$t->get_ok('/some/route' => {'User-Agent' => 'curl'})
  ->status_is(200);
```

**Helper Tests**: Test helpers in isolation using the app context:
```perl
my $packages = $t->app->proxypan->packages;
ok($packages->size > 0, 'packages returned from database');
```

**Database Tests**: Use temporary SQLite database:
```perl
$ENV{SQLITE_DB} = ':memory:';  # In-memory DB for tests
my $t = Test::Mojo->new('proxypan');
```

**Proxy Tests**: Mock external CPAN requests with `Test::Mojo` or `Mojo::UserAgent::Mockable`

### Running Tests
```bash
# Run all tests
prove -lv t/

# Run specific test file
perl -Ilib t/basic.t

# With test coverage
cover -test
```

## Debugging Tips

- **Log levels**: Use `$c->log->trace/debug/info/error()` for request flow debugging
- **Request inspection**: Check `before_dispatch` hook in `Hooks.pm` for auth/URL logging
- **Cache paths**: `$c->proxypan->paths` returns Mojo::Collection of search directories
- **Database queries**: Enable SQLite debug: `$sql->db->query(...)->hash` and check logs
- **Proxy loops**: Verify `X-DarkPan` header is set when forwarding to prevent recursion

## File Locations
- **Local cache**: `authors/id/` (or `DARKPAN_PATH` env var)
- **SQLite DB**: `proxypan.$mode.db` (default) or `SQLITE_DB` env var
- **Dependencies**: `cpanfile` lists required CPAN modules
- **Config**: `mcpani.conf` for CPAN::Mini::Inject (not used by plugin directly)
