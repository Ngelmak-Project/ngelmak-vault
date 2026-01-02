# 🔐 Ngelmak Vault: Secret management for Ngelmak

This documentation explains how to setup **HashiCorp Vault** as secret managemnt for Ngelmak-Project.  
The goal is to securely manage:

- A **JWT signing key** (for JJWT).
- **Postgres database credentials** (dynamic secrets).
- Transit encryption.
- Etc.

---

### 📂 Recommended Folder Layout

```bash
ngelmak-bao/
├── data/                 # Persistent Raft data (never touch manually)
├── config/               # OpenBao server config files
│   ├── config.hcl
│   ├── policies/
│   │   ├── spring-app-policy.hcl
│   │   ├── db-admin-policy.hcl
│   │   └── ...
│   ├── roles/            # Optional: JSON definitions for AppRoles
│   └── scripts/          # Optional: init/unseal scripts
└── README.md
```

---

### 📦 Prerequisites

This is the clean, stable, production‑ready way to run:

- PostgreSQL  
- OpenBao dynamic database credentials  
- Spring Boot  
- Hibernate auto‑DDL (optional)  

---
```bash
$ docker exec -it ngelmak-postgres bash
```

After the container starts, connect:
```bash
psql -U admin postgres
```

Change the admin password (optional but recommended)
```bash
ALTER USER admin WITH PASSWORD 'new-admin-password';

ALTER ROLE
```

```bash
\du
```

### 1. PostgreSQL roles

#### Create the OpenBao admin role (superuser)

```sql
CREATE ROLE baoadmin WITH LOGIN SUPERUSER PASSWORD 'baopass';
```
**Change baoadmin password**

#### Create the application database

```sql
CREATE DATABASE ngelmakdb OWNER baoadmin;
```

#### Create the schema owner role

```sql
CREATE ROLE app_migrator WITH LOGIN PASSWORD 'migratorpass';
GRANT ALL PRIVILEGES ON DATABASE ngelmakdb TO app_migrator;
```

Switch to the database:

```sql
\c ngelmakdb
```

Grant schema privileges:

```sql
GRANT USAGE, CREATE ON SCHEMA public TO app_migrator;
```

---

## 2. OpenBao: Configure the database connection

---

Now you just need the **OpenBao database engine configuration**:

- `bao write database/config/postgres`  
- `bao write database/roles/<your-role>`  

---

```bash
docker exec -it ngelmak-openbao sh
```

```bash
export BAO_ADDR=http://127.0.0.1:8200
```

```bash
bao operator init

Unseal Key 1: m2Al5MVNLIrENgwTAmzvB9lJVZf/Y/A5M6tSu3rhzISq
Unseal Key 2: KdMAtKnAHKRwKUQLAuWIexS3rLBOLox/hXRqO6/isV6+
Unseal Key 3: V64wvayWAzySBRghJtBoBZbluWN6Rp4shqr24Ai5In9+
Unseal Key 4: 4evRAmcxzkGkYeTtcI6uKVcj48nvLkh5RxqFtUJTb8GP
Unseal Key 5: yt5vb6yBFLe5wqkRbGMWICrgQOEq5WWLO4Yv5cayImtY

Initial Root Token: s.Ctt6mf5hu0NCBzOEnY9tWEMD

Vault initialized with 5 key shares and a key threshold of 3. Please securely
distribute the key shares printed above. When the Vault is re-sealed,
restarted, or stopped, you must supply at least 3 of these keys to unseal it
before it can start servicing requests.

Vault does not store the generated root key. Without at least 3 keys to
reconstruct the root key, Vault will remain permanently sealed!

It is possible to generate new unseal keys, provided you have a quorum
of existing unseal keys shares. See "bao operator rotate-keys" for more
information.
```


```bash
bao operator unseal m2Al5MVNLIrENgwTAmzvB9lJVZf/Y/A5M6tSu3rhzISq
bao operator unseal KdMAtKnAHKRwKUQLAuWIexS3rLBOLox/hXRqO6/isV6+
bao operator unseal V64wvayWAzySBRghJtBoBZbluWN6Rp4shqr24Ai5In9+

Key                     Value
---                     -----
Seal Type               shamir
Initialized             true
Sealed                  false
Total Shares            5
Threshold               3
Version                 2.4.4
Build Date              2025-11-24T19:54:48Z
Storage Type            raft
Cluster Name            bao-cluster-f0ff3736
Cluster ID              50bdc694-9e9a-9591-de52-599f8e841fb0
HA Enabled              true
HA Cluster              n/a
HA Mode                 standby
Active Node Address     <none>
Raft Committed Index    27
Raft Applied Index      27
```

## 🗄️ Enable the database secrets engine

```bash
bao login s.Ctt6mf5hu0NCBzOEnY9tWEMD

Success! You are now authenticated. The token information displayed below is
already stored in the token helper. You do NOT need to run "bao login" again.
Future OpenBao requests will automatically use this token.

Key                  Value
---                  -----
token                s.Ctt6mf5hu0NCBzOEnY9tWEMD
token_accessor       YUk1Nu3X1DQGWk2zqT4tQp5S
token_duration       ∞
token_renewable      false
token_policies       ["root"]
identity_policies    []
policies             ["root"]
```

```bash
bao secrets enable database

Success! Enabled the database secrets engine at: database/
```


Configure OpenBao to connect to PostgreSQL
This is where OpenBao takes over the admin password.

Use `baoadmin` as the connection user in OpenBao’s database engine.

This is where OpenBao learns how to connect to PostgreSQL using `baoadmin`.

Configure Postgres connection:

```bash
bao write database/config/ngelmakdb-config \
    plugin_name=postgresql-database-plugin \
    allowed_roles="ngelmak-rw-role" \
    connection_url="postgresql://{{username}}:{{password}}@postgres:5432/ngelmakdb?sslmode=disable" \
    username="baoadmin" \
    password="baopass"

Success! Data written to: database/config/ngelmakdb-config
```

- **database/config/ngelmakdb-config** → name of the DB config.
- **plugin_name** → database driver (for Postgres: `postgresql-database-plugin`).
- **connection_url** → template OpenBao uses, inserting generated creds into `{{username}}` and `{{password}}`.
- **username/password** → privileged DB account OpenBao uses to create/revoke users.
- **allowed_roles** → which OpenBao roles can request creds from this config.

Use `bao list database/config` to list configs and `bao delete database/config/<config-name>` to delete `config-name`.

---

- `baoadmin` is SUPERUSER → can create dynamic users + grant privileges  
- `allowed_roles="ngelmak-rw-role"` → only this role can be requested  
- `connection_url` points to `ngelmakdb` (real app DB)  

This is the foundation.
Define a role for dynamic users:

```bash
bao write database/roles/ngelmak-rw-role \
    db_name=ngelmakdb-config \
    creation_statements="\
        CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; \
        GRANT USAGE ON SCHEMA public TO \"{{name}}\"; \
        GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO \"{{name}}\"; \
        GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO \"{{name}}\"; \
        ALTER DEFAULT PRIVILEGES FOR ROLE app_migrator IN SCHEMA public \
            GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO \"{{name}}\"; \
        ALTER DEFAULT PRIVILEGES FOR ROLE app_migrator IN SCHEMA public \
            GRANT USAGE, SELECT ON SEQUENCES TO \"{{name}}\"; \
    " \
    default_ttl="24h" \
    max_ttl="48h"

Success! Data written to: database/roles/ngelmak-rw-role
```
Create or update a role definition named `ngelmak-rw-role` inside the database secrets engine.
- **database/roles/ngelmak-rw-role** → OpenBao role name, must be listed in allowed_roles to be usable.
- **db_name** → links to the DB config (`ngelmakdb-config`).
- **creation_statements** → SQL template for creating users; OpenBao injects `{{name}}`, `{{password}}`, `{{expiration}}`.
- **default_ttl** → default credential lifetime.
- **max_ttl** → maximum lifetime of credentials.

Use `bao list database/roles` to list roles and `bao delete database/roles/<role-name>` to delete `role-name`.

```bash
bao list database/roles

Keys
----
ngelmak-rw-role
```

---

- Dynamic users get CRUD on all existing tables  
- Dynamic users get CRUD on all future tables created by `app_migrator`  
- Dynamic users never own tables  
- Rotation is safe  
- No privilege drift  
- No broken access after rotation  

---

##🎯 How Spring Boot will request credentials

The app will call:

```bash
bao read database/creds/ngelmak-rw-role

Key                Value
---                -----
lease_id           database/creds/ngelmak-rw-role/q0Y5zgnF88zJ7PZYLXi0GQGF
lease_duration     24h
lease_renewable    true
password           YPvXyQ8fEf3Wr-nr9cC9
username           v-root-ngelmak--NQiueQV69JiGulzxWmpD-1767183902
```

And receive:

```json
{
  "username": "...",
  "password": "..."
}
```

These values populate:

```yaml
spring.datasource.username=${OPENBAO_DB_USERNAME}
spring.datasource.password=${OPENBAO_DB_PASSWORD}
```


## Enable KV Secrets Engine

The KV engine stores static secrets such as your JWT signing key.

```bash
bao secrets enable kv

Success! Enabled the kv secrets engine at: kv/
```
- **-path=secret** → mount point name; secrets will live under `secret/`.
- **kv** → type of secrets engine (key‑value).

Store the JWT secret:

```bash
bao kv put kv/jjwt jwt-secret-key="NzgwODE3NjExMzk1MDFjYzc2NmRjMmM2Yjc0ZTYyMGUxODM3ZThjMzk0ZTliMTE0MjhlNjliOWRhYTI2MzFkN2RkMGU3NDVhYTA0MzRkNTBkNGEzYmZlMzE1MTg4ZjVmYzA5NmFlNTEyZjkyZjYxMGJlMTM1NmU3ZmU0NDg2Yjk="

Success! Data written to: kv/jjwt
```
- **secret/jjwt** → path where the secret is stored.
- **<key>="<value>"** → field name and value stored at that path.

Check for the secret key with:
```bash
bao kv get kv/jjwt

========= Data =========
Key               Value
---               -----
jwt-secret-key    NzgwODE3NjExMzk1MDFjYzc2NmRjMmM2Yjc0ZTYyMGUxODM3ZThjMzk0ZTliMTE0MjhlNjliOWRhYTI2MzFkN2RkMGU3NDVhYTA0MzRkNTBkNGEzYmZlMzE1MTg4ZjVmYzA5NmFlNTEyZjkyZjYxMGJlMTM1NmU3ZmU0NDg2Yjk=
```




## Connect to postgres to check query access [optional]

```bash
psql "postgresql://v-root-ngelmak--NQiueQV69JiGulzxWmpD-1767183902:YPvXyQ8fEf3Wr-nr9cC9@postgres:5432/ngelmakdb?sslmode=disable"

psql (16.11 (Debian 16.11-1.pgdg13+1))
Type "help" for help.
```

Everything stays clean and stable.

---


## 3. Spring Boot configuration

Spring Boot runs in **two modes**.

- **bootstrap** → used only when creating/updating tables  
- **default** → used for normal runtime with rotated credentials  

---

### A. Schema initialization mode (run once)

Use this when you want Hibernate to create or update the schema.

`application-bootstrap.yml`:

```yaml
spring:
  datasource:
    url: jdbc:postgresql://localhost:5432/ngelmakdb
    username: ${BOOTSTRAP_DB_USERNAME}
    password: ${BOOTSTRAP_DB_PASSWORD}
  jpa:
    hibernate:
      ddl-auto: update   # or create / create-drop
    show-sql: true
```

Pass the real credentials via command line:
#### If you run with Maven:
```bash
BOOTSTRAP_DB_USERNAME=app_migrator \
BOOTSTRAP_DB_PASSWORD=migratorpass \
mvn spring-boot:run -Dspring-boot.run.profiles=bootstrap
# or
BOOTSTRAP_DB_USERNAME=app_migrator \
BOOTSTRAP_DB_PASSWORD=migratorpass \
mvn spring-boot:run -Dspring-boot.run.profiles=bootstrap -Dspring-boot.run.arguments="--liquibase.run=true"
```

#### If you run the JAR:
```bash
BOOTSTRAP_DB_USERNAME=app_migrator \false
BOOTSTRAP_DB_PASSWORD=migratorpass \
java -jar app.jar --spring.profiles.active=bootstrap
# or
BOOTSTRAP_DB_USERNAME=app_migrator \false
BOOTSTRAP_DB_PASSWORD=migratorpass \
java -jar app.jar --spring.profiles.active=bootstrap --liquibase.run=true
```

---

### B. Runtime mode (normal operation with rotated credentials)

`application.yml`:

```yaml
spring:
  datasource:
    url: jdbc:postgresql://localhost:5432/ngelmakdb
    username: ${OPENBAO_DB_USERNAME}
    password: ${OPENBAO_DB_PASSWORD}
  jpa:
    hibernate:
      ddl-auto: none
```

Spring Boot now uses dynamic credentials from OpenBao.

Dynamic users can:

- SELECT  
- INSERT  
- UPDATE  
- DELETE  

Dynamic users cannot:

- CREATE TABLE  
- ALTER TABLE  
- DROP TABLE  

This keeps the schema stable and rotation safe.

---

## 4. Final architecture overview

```
admin
  (initial container superuser)

baoadmin
  (OpenBao superuser)
  └── creates dynamic users
  └── grants privileges

app_migrator
  (schema owner)
  └── Spring Boot schema initialization
  └── owns all tables
  └── default privileges for dynamic users

dynamic users
  (runtime)
  └── CRUD only
  └── rotated by OpenBao
```
----

## 3. Define a Policy

A policy in OpenBao defines what a client is allowed to do. It restricts what your app can access.
It is a set of rules that grants capabilities (read, list, update, delete) on specific paths.

A policy does not create users.
A policy does not store secrets.
A policy simply defines permissions.

Spring Boot (via AppRole) receives a token that is bound to a policy, and that token determines what Spring is allowed to access.

Create `core-app-policy.hcl`:

```bash
vi /etc/openbao/policies/core-app-policy.hcl
```

```hcl
# Dynamic PostgreSQL credentials (read-only access to generated creds)
path "database/creds/ngelmak-rw-role" {
  capabilities = ["read"]
}

# KV reading JWT secret
path "kv/*" {
  capabilities = ["read"]
}

# Transit encryption (encrypt/decrypt/sign/verify)
path "transit/encrypt/*" {
  capabilities = ["update"]
}
path "transit/decrypt/*" {
  capabilities = ["update"]
}
path "transit/sign/*" {
  capabilities = ["update"]
}
path "transit/verify/*" {
  capabilities = ["update"]
}
```
- **path** → Vault API path to control (KV reads use `kv/<name>`).
- **capabilities** → allowed actions (e.g., `read`, `create`, `update`, `delete`, `list`).

Load the policy:

```bash
bao policy write ngelmak-core-policy /etc/openbao/policies/ngelmak-core-policy.hcl

Success! Uploaded policy: ngelmak-core-policy
```
- **ngelmak-core-policy** → name of the policy.
- **../ngelmak-core-policy.hcl** → file containing the rules.

## 4. 🔐 Enable AppRole Authentication

AppRole is the recommended auth method for applications.

```bash
bao auth enable approle

Success! Enabled approle auth method at: approle/
```
- **approle** → type of auth method.

Create an AppRole:

```bash
bao write auth/approle/role/ngelmak-core-role \
  policies="ngelmak-core-policy" \
  secret_id_ttl=48h \
  token_ttl=1h \
  token_max_ttl=4h

Success! Data written to: auth/approle/role/ngelmak-core-role
```
- **policies** → attach the policy you created (defines what the app can access).
- **secret_id_ttl** → how long the Secret ID remains valid before rotation.
- **token_ttl** → default lifetime of the Vault token issued to the app.
- **token_max_ttl** → maximum lifetime; tokens cannot be renewed beyond this limit.

Fetch Role ID:

```bash
bao read auth/approle/role/ngelmak-core-role/role-id

Key        Value
---        -----
role_id    8a23bd57-a50a-79a3-0ae7-4964e5918ac0
```

- **auth/approle/role/<role-name>/role-id** → path that returns the Role ID (non‑secret identifier).

Generate Secret ID:

```bash
bao write -f auth/approle/role/ngelmak-core-role/secret-id

Key                   Value
---                   -----
secret_id             bf80c8a5-3d02-2515-5bf5-7128edf18d53
secret_id_accessor    bfa8fb77-58d0-5a2e-2551-148bd3652db9
secret_id_num_uses    0
secret_id_ttl         48h

```
- **-f** → force create; no payload needed.
- **auth/approle/role/<role-name>/secret-id** → path that issues a Secret ID (secret half of AppRole).

Spring Boot uses these to authenticate and automatically:
- authenticate via AppRole
- read KV secrets
- use transit keys
- fetch dynamic DB credentials
- renew leases
- rotate credentials

---

## 🧩 Configure Spring Boot to use AppRole

In application.yml (runtime mode):

```yaml
spring:
  vault:
    uri: http://localhost:8200
    authentication: approle
    app-role:
      role-id: ${VAULT_ROLE_ID}
      secret-id: ${VAULT_SECRET_ID}

    database:
      enabled: true
      backend: database
      role: ngelmak-rw-role
```
- **role_id* → This is the Role ID of AppRole in OpenBao.
- **secret_id* → This is the Secret ID generated for your AppRole.
- **role* → This is the name of the OpenBao database role Spring should use to fetch dynamic DB credentials. Spring will call: `/v1/<backend>/creds/<role>`.
- **app-role-path* → This is the mount path of the AppRole authentication engine. If auth enabled AppRole like this: `bao auth enable approle`, then the path is: `auth/approle`.

The app can be run by using the generated values:

```bash
curl \
  --request POST \
  --data '{"role_id":"8a23bd57-a50a-79a3-0ae7-4964e5918ac0", "secret_id":"bf80c8a5-3d02-2515-5bf5-7128edf18d53"}' \
  http://127.0.0.1:8200/v1/auth/approle/login | jq

{
  ...
  "auth": {
    "client_token": "s.NvCMwxOS7oPQjSQUyVyvwls5",
    "policies": [ "default", "ngelmak-core-policy" ],
    "lease_duration": 3600,
    "renewable": true
  }
}
```

```bash
VAULT_ROLE_ID=8a23bd57-a50a-79a3-0ae7-4964e5918ac0 \
VAULT_SECRET_ID=bf80c8a5-3d02-2515-5bf5-7128edf18d53 \
mvn spring-boot:run
```


---

## 🔐 Using `spring.config.import=vault://`

Spring Boot supports loading configuration directly from HashiCorp Vault using the **Config Data API** (introduced in Spring Boot 2.4+).  
Enabling:

```yaml
spring.config.import: vault://
```

activates **Vault Config Data**, which means:

- Vault secrets are fetched **before** the Spring application context starts.  
- Loaded secrets are injected into the **Environment** just like properties from `application.yml`.  
- If `fail-fast=true`, the application will stop immediately if Vault is unreachable or misconfigured.

### ⚠️ Requirement: At Least One Vault Backend Must Be Enabled

The `vault://` import is only valid if **at least one Vault backend that provides configuration data is enabled**, such as:

- `spring.cloud.vault.kv.enabled=true`
- `spring.cloud.vault.database.enabled=true`

If **all** config-producing backends are disabled, Spring Boot has nothing to load from Vault and will fail with:

```
Config data location 'vault://' does not exist
```

To avoid this, ensure at least one backend is active, or make the import optional:

```yaml
spring.config.import: optional:vault://
```