
# Cloud to Local MySQL Replication (AWS RDS MySQL → Local Docker MySQL Replica)

## Objective
Set up replication from a managed cloud MySQL database (AWS RDS MySQL) to a local MySQL database running inside Docker, such that:

- Local DB stays in sync with cloud DB
- If the Docker container restarts/crashes, replication resumes automatically
- If the local volume/data is lost, the replica can be re-seeded and replication resumes
- No manual intervention is required for normal restarts

---

## Architecture

```
        ┌─────────────────────────────────────────┐
        │           AWS RDS MySQL (SOURCE)         │
        │  - user: repl_user (REPLICATION CLIENT)  │
        └─────────────────────┬───────────────────┘
                              │   Binlog events
                              ▼
        ┌─────────────────────────────────────────┐
        │     Local Docker MySQL (REPLICA)         │
        │                                         │
        │  - Persistent volume: ./mysql-data       │
        │  - Seed dump stored: ./backups/seed.sql  │
        │  - Replica identity: ./meta/replica_id   │
        │  - Replication filter: ONLY appdb.*      │
        └─────────────────────────────────────────┘
```

---

## Replication method chosen and why

### ✅ Method: Binlog File/Position Replication (Auto_Position = 0)
We use classic replication with:

- `SHOW MASTER STATUS` on the source to get:
  - `File` (e.g., `mysql-bin-changelog.000118`)
  - `Position` (e.g., `820`)
- Configure replica using `CHANGE REPLICATION SOURCE TO ... SOURCE_LOG_FILE / SOURCE_LOG_POS`

---

## Persistence handling

- Local MySQL data directory is persisted using a Docker bind mount:

  - `./mysql-data:/var/lib/mysql`

This ensures:
- Container restarts do not lose data
- Replication metadata remains intact across restarts

---

## Restart recovery (no manual intervention)

### Normal restart (`docker compose restart local_mysql`)
- MySQL replica starts with the same data directory
- Replication configuration persists in local mysql system tables
- Replica connects again to the RDS source
- IO thread + SQL thread should return to `Yes` automatically

Verification:

```bash
mysql --protocol=tcp -h 127.0.0.1 -P 3307 -uroot -plocal_root_password -e "SHOW REPLICA STATUS\G" \
| egrep "Replica_IO_Running|Replica_SQL_Running|Seconds_Behind_Source|Last_IO_Error|Last_SQL_Error"
```

Expected:

- `Replica_IO_Running: Yes`
- `Replica_SQL_Running: Yes`
- `Seconds_Behind_Source: 0` (or small number)

---

## Repository Structure

```
cloud-to-local-pg-replication-mysql/
├── docker-compose.yml
├── .env
├── docker/
│   └── mysql/
│       ├── conf/
│       │   └── my.cnf
│       └── init/
│           └── 01_seed_and_configure_replication.sh
├── mysql-data/           # persisted data (bind mount)
├── backups/              # seed dump output
└── meta/                 # persistent replica identity
```

---

## Setup Steps

### 1) RDS MySQL prerequisites
On AWS RDS MySQL, ensure:
- `binlog_format = ROW`
- `SHOW MASTER STATUS;` returns a file/position (not empty)

Verify on RDS:

```sql
SHOW VARIABLES LIKE 'binlog_format';
SHOW VARIABLES LIKE 'log_bin';
SHOW MASTER STATUS;
```

### 2) Create replication user on RDS
Run on RDS (as admin):

```sql
CREATE USER 'repl_user'@'%' IDENTIFIED BY 'repl_password';
GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO 'repl_user'@'%';
FLUSH PRIVILEGES;
```

Also ensure RDS Security Group inbound allows your local IP to reach port **3306**.

### 3) Local Docker compose
Your `docker-compose.yml` runs a local MySQL container and mounts:
- data: `./mysql-data`
- config: `./docker/mysql/conf/my.cnf`
- init script: `./docker/mysql/init` (via entrypoint init dir if mounted)

Start:

```bash
docker compose up -d
docker logs -f local_mysql_replica
```

---

## How initial sync (seed) works

The init script does:
1. Wait for local MySQL to be ready
2. Take a consistent dump from RDS using `mysqldump`
3. Import into local database
4. Read `SHOW MASTER STATUS` from RDS to capture **File/Position**
5. Configure replication on replica using file/position
6. Start replication

---

## Testing: replication, restart recovery, and failure recovery

### A) Replication works
1) Insert on RDS:

```sql
USE appdb;
INSERT INTO users(name) VALUES ('mysql-cloud-test-1');
```

2) Verify on local:

```bash
mysql --protocol=tcp -h 127.0.0.1 -P 3307 -uroot -plocal_root_password appdb -e \
"SELECT * FROM users WHERE name='mysql-cloud-test-1';"
```

### B) Restart recovery (container restart)
```bash
docker compose restart local_mysql
sleep 5
mysql --protocol=tcp -h 127.0.0.1 -P 3307 -uroot -plocal_root_password -e "SHOW REPLICA STATUS\G" \
| egrep "Replica_IO_Running|Replica_SQL_Running|Last_SQL_Error"
```

Expected:
- IO: Yes
- SQL: Yes
- Last_SQL_Error: empty

If SQL stops, check worker errors:

```bash
mysql --protocol=tcp -h 127.0.0.1 -P 3307 -uroot -plocal_root_password -e \
"SELECT WORKER_ID, LAST_ERROR_NUMBER, LAST_ERROR_MESSAGE
 FROM performance_schema.replication_applier_status_by_worker
 WHERE LAST_ERROR_NUMBER<>0\G"
```

### C) Volume loss recovery (reseed)
This simulates disk loss:

```bash
docker compose down
sudo rm -rf mysql-data
mkdir -p mysql-data meta backups
sudo chmod -R 777 mysql-data meta backups
docker compose up -d
docker logs -f local_mysql_replica
```

Expected:
- script reseeds from RDS
- replication starts again automatically

---

## Conclusion
This repo demonstrates a **self-healing MySQL replication setup** from AWS RDS to a local Docker replica, with:

- Full initial seeding
- Continuous replication
- Persistent local storage
- Automatic restart recovery
