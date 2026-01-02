# 🔐 Ngelmak Vault: Secret management for Ngelmak

This documentation explains how to setup **HashiCorp Vault** as secret managemnt for Ngelmak-Project.  
The goal is to securely manage:

- A **JWT signing key** (for JJWT).
- **Postgres database credentials** (dynamic secrets).
- Transit encryption.
- Etc.

---

## 📦 Prerequisites

- HashiCorp Vault installed and running (e.g., see install for [Linux](https://developer.hashicorp.com/vault/install#linux)).
- Or go for container setup. 

---

## 🏗️ Vault Deployment Mode Setup

### 📂 Recommended Folder Layout

```bash
/var/vault/
├── config/       # Vault server configs (vault.hcl, etc.)
├── policies/     # Policy files (.hcl)
├── approles/     # AppRole definitions (optional JSON/HCL)
├── tls/          # Certificates if TLS enabled
└── logs/         # Vault logs
```

```bash
# Create the main Vault directory
sudo mkdir -p /var/vault/data
sudo mkdir -p /var/vault/config
sudo mkdir -p /var/vault/policies
sudo mkdir -p /var/vault/approles
sudo mkdir -p /var/vault/tls
sudo mkdir -p /var/vault/logs
```

### 1. Create a Vault Configuration File (config.hcl)

```bash
storage "raft" {
  path    = "/var/vault/data"
  node_id = "node1"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = "true"   # disable TLS for testing; enable TLS in production
}

api_addr = "http://127.0.0.1:8200"
cluster_addr = "http://127.0.0.1:8201"
disable_mlock = true
ui = true   # enables the Vault web UI
```

- **storage "file"** → tells Vault to use the local filesystem (see also **storage "raft"**).
- **listener "tcp"** → network listener; configure TLS in real deployments.
- **api_addr / cluster_addr** → advertise addresses for clients and cluster peers.
- **ui = true** → turns on the built‑in web interface.

```bash
sudo nano /var/vault/config/config.hcl
```

### 2. Start Vault in Server Mode
```bash
sudo vault server -config=/var/vault/config/config.hcl
```

- **-config** → points to your configuration file. Unlike -dev, this persists secrets in the backend.

### 2.1. Export Vault Address

To ensure the client can communicate with the Vault server, export the Vault address
```bash
export VAULT_ADDR='http://127.0.0.1:8200'
```

### 3. Initialize Vault

```bash
vault operator init -key-shares=5 -key-threshold=3
```
- **-key-shares=5** → generate 5 unseal keys.
- **-key-threshold=3** → require 3 of them to unseal Vault.
  This will show:
  -  Unseal Keys → must be stored securely (e.g., HSM, secret manager).
  - Initial Root Token → used for initial setup; rotate and revoke after creating policies.

### 4. Unseal Vault (or use the ui) and save the root token

```bash
vault operator unseal <unseal-key-1>
vault operator unseal <unseal-key-2>
vault operator unseal <unseal-key-3>

vault status
Key                     Value
---                     -----
Seal Type               shamir
Initialized             true
Sealed                  false
...
```

Provide the threshold number of keys (here 3/5).

### 5. Secure the Root Token (optional)

Use the root token only to create admin policies and AppRoles.

Then revoke or rotate it.

Applications (like Spring Boot) should authenticate via AppRole, not the root token.

## Use the root token to login

You need to connect to vault for the following commands
```bash
vault login
```

```
Success! You are now authenticated. The token information displayed below
is already stored in the token helper. You do NOT need to run "vault login"
again. Future Vault requests will automatically use this token.

Key                  Value
---                  -----
token                <token>
token_accessor       <token>
token_duration       ∞
token_renewable      false
token_policies       ["root"]
identity_policies    []
policies             ["root"]
```

## Enable KV Secrets Engine

The KV engine stores static secrets such as your JWT signing key.

```bash
vault secrets enable -path=secret kv
```
- **-path=secret** → mount point name; secrets will live under `secret/`.
- **kv** → type of secrets engine (key‑value).

Store the JWT secret:

```bash
vault kv put secret/jjwt jwt-secret-key="super-secret"
```
- **secret/jjwt** → path where the secret is stored.
- **jwt-secret-key="super-secret"** → field name and value stored at that path.

Check for the secret key with `vault kv get secret/jjwt`.

---

## Enable Database Secrets Engine

Vault can generate **dynamic Postgres credentials**.

```bash
vault secrets enable database
```

- **database** → type of secrets engine for databases.

Configure Postgres connection:

```bash
vault write database/config/my-postgres \
  plugin_name=postgresql-database-plugin \
  connection_url="postgresql://{{username}}:{{password}}@db-host:5432/postgres" \
  username="vaultadmin" \
  password="vaultadminpassword" \
  allowed_roles="springboot-db-role"
```

- **database/config/my-postgres** → name of this DB config.
- **plugin_name** → database driver (for Postgres: `postgresql-database-plugin`).
- **connection_url** → template Vault uses, inserting generated creds into `{{username}}` and `{{password}}`.
- **username/password** → privileged DB account Vault uses to create/revoke users.
- **allowed_roles** → which Vault roles can request creds from this config.

Define a role for dynamic users:

```bash
vault write database/roles/springboot-db-role \
  db_name=my-postgres \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';" \
  default_ttl="1h" \
  max_ttl="24h"
```

- **database/roles/springboot-db-role** → Vault role name.
- **db_name** → links to the DB config (`my-postgres`).
- **creation_statements** → SQL template for creating users; Vault injects `{{name}}`, `{{password}}`, `{{expiration}}`.
- **default_ttl** → default credential lifetime.
- **max_ttl** → maximum lifetime of credentials.

---

## 3. Define a Policy

Policies restrict what your app can access.

Create `springboot-policy.hcl`:

```bash
# Allow reading JWT secret
path "secret/data/jjwt" {
  capabilities = ["read"]
}

# Allow reading dynamic Postgres creds
path "database/creds/springboot-db-role" {
  capabilities = ["read"]
}
```

- **path** → Vault API path to control (KV v2 reads use `secret/data/<name>`).
- **capabilities** → allowed actions (e.g., `read`, `create`, `update`, `delete`, `list`).

Load the policy:

```bash
vault policy write springboot-policy springboot-policy.hcl
```

- **springboot-policy** → name of the policy.
- **springboot-policy.hcl** → file containing the rules.

---

## 4. Enable AppRole Authentication

AppRole is the recommended auth method for applications.

`vault auth enable approle`

- **approle** → type of auth method.

Create an AppRole:

```bash
vault write auth/approle/role/springboot \
  policies="springboot-policy" \
  secret_id_ttl=24h \
  token_ttl=1h \
  token_max_ttl=4h
```

- **policies** → attach the policy you created (defines what the app can access).
- **secret_id_ttl** → how long the Secret ID remains valid before rotation.
- **token_ttl** → default lifetime of the Vault token issued to the app.
- **token_max_ttl** → maximum lifetime; tokens cannot be renewed beyond this limit.

Fetch Role ID:

```bash
vault read auth/approle/role/springboot/role-id
```

- **auth/approle/role/springboot/role-id** → path that returns the Role ID (non‑secret identifier).

Generate Secret ID:

```bash
vault write -f auth/approle/role/springboot/secret-id
```

- **-f** → force create; no payload needed.
- **auth/approle/role/springboot/secret-id** → path that issues a Secret ID (secret half of AppRole).

---

## ✅ Summary

- **KV engine** → stores JWT secret.
- **Database engine** → generates dynamic Postgres credentials.
- **Policy** → restricts access to only required paths.
- **AppRole** → authenticates Spring Boot app.


















































# 📁 **2. application.yml (default runtime mode)**  
This is the file Spring Boot loads automatically.

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

This is your **normal mode**.  
Spring Boot uses dynamic credentials from OpenBao.

---

# 📁 **3. application-bootstrap.yml (schema creation mode)**  
This file is only used when you explicitly activate the `bootstrap` profile.

```yaml
spring:
  datasource:
    url: jdbc:postgresql://localhost:5432/ngelmakdb
    username: app_migrator
    password: migratorpass
  jpa:
    hibernate:
      ddl-auto: update   # or create / create-drop
    show-sql: true
```

This is your **schema initialization mode**.

---

# 🚀 **4. How to run Spring Boot in schema creation mode**

Use the `bootstrap` profile:

### If you run with Maven:
```bash
mvn spring-boot:run -Dspring-boot.run.profiles=bootstrap
```

### If you run the JAR:
```bash
java -jar app.jar --spring.profiles.active=bootstrap
```

### If you run with Gradle:
```bash
./gradlew bootRun --args='--spring.profiles.active=bootstrap'
```

This will:

- connect as `app_migrator`
- create/update tables
- apply default privileges for dynamic users
- exit or continue running depending on your app

---

# 🟢 **5. How to run Spring Boot normally (runtime mode)**

Just run it normally — no profile needed:

### Maven:
```bash
mvn spring-boot:run
```

### JAR:
```bash
java -jar app.jar
```

### Gradle:
```bash
./gradlew bootRun
```

This uses:

- dynamic credentials from OpenBao  
- `ddl-auto: none`  
- CRUD‑only dynamic users  

---

# 🎉 **6. Summary for your `.md`**

```
Spring Boot uses two profiles:

1. bootstrap → schema creation/update
   Run with:
     mvn spring-boot:run -Dspring-boot.run.profiles=bootstrap
     java -jar app.jar --spring.profiles.active=bootstrap

2. default → runtime with OpenBao dynamic credentials
   Run normally:
     mvn spring-boot:run
     java -jar app.jar
```

---

If you want, I can generate:

- a full `.md` section for “Spring Boot schema migration workflow”
- a diagram showing the two modes
- a script to automate switching modes

Just tell me.