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

## Two backends in one job

`cells.sh` accepts a second site and backend (`SITE_DIR_B`/`DB_B`, set by a job's
`SITE_B`/`DB_B`): each side then gets its own network, database container (the
alias `db` on each network), site directory and session cookie. With the runtime
held equal on both sides (`RUNTIME_A=RUNTIME_B=freeunit`) the job's A/B delta *is*
the backend delta, measured inside one window against the job's own null phase.
Jobs 39-41 use that for `mysqli` vs `mysql` under FreeUnit and under FPM
(`scripts/campaign.steps.mysqli`); the default single-backend path is untouched.

`mysqli` is worth a pedantic pass because it is the core driver a future PHP
worker target (issue 596) would keep a live connection in: classic mode measures
the per-request driver cost, worker mode would measure the connection reuse.
