# Database backends the benchmark supports

| DB key | Drupal driver | Namespace / autoload | Server |
|---|---|---|---|
| `mysql` (default) | `mysql` (PDO) | `Drupal\mysql\Driver\Database\mysql` / `core/modules/mysql/src/Driver/Database/mysql/` | MariaDB 10.11 |
| `mysqli` | `mysqli` (experimental core driver) | `Drupal\mysqli\Driver\Database\mysqli` / `core/modules/mysqli/src/Driver/Database/mysqli/` | MariaDB 10.11, same server, different PHP extension |
| `pgsql` | `pgsql` | `Drupal\pgsql\Driver\Database\pgsql` / `core/modules/pgsql/src/Driver/Database/pgsql/` | PostgreSQL 17, `trust` auth, `drupal` DB |
| `sqlite` | `sqlite` | `Drupal\sqlite\Driver\Database\sqlite` / `core/modules/sqlite/src/Driver/Database/sqlite/` | a file under `sites/default/files/.sqlite`, no server |

`mysql` and `mysqli` hit the same MariaDB data; only the PHP extension and the
driver implementation differ, so a `mysql` vs `mysqli` pair isolates the
experimental core driver. `sqlite` and `pgsql` need their own installation (the
driver cannot be swapped under an installed site), which is why each backend gets
its own site directory (`site/<line>-<profile>-<db>`) and its own `meta.txt` line.

The images carry `pdo_mysql`, `mysqli`, `pdo_pgsql` and `pdo_sqlite`, so one PHP
build serves every backend.

Why this axis matters for FreeUnit: `mysqli` keeps a native connection that the
experimental driver reuses, and a PHP worker target (issue 596) would let a
connection survive between requests -- the case where a persistent, in-process
worker can beat a per-request connection setup on both SAPI stacks.
