# 🔐 Ngelmak Vault: Secret Management for Ngelmak

**HashiCorp Vault** is a secrets management platform that securely stores, rotates, and controls access to sensitive data. This documentation guides you through deploying **OpenBAO** (the open-source Vault fork) and configuring it for the Ngelmak project. Vault will manage your **JWT signing keys**, **dynamically generate database credentials**, handle **encryption transit**, and more—all with fine-grained access control via policies and authentication methods.

---

## 📑 Table of Contents

- [Prerequisites](#prerequisites)
- [Vault Deployment](#vault-deployment)
  - [Directory Setup](#directory-setup)
  - [Configuration File](#configuration-file)
  - [Docker Compose & Startup](#docker-compose--startup)
  - [Initialization & Unsealing](#initialization--unsealing)
  - [Secure Root Token](#secure-the-root-token)
- [Secrets Configuration](#secrets-configuration)
  - [KV Secrets Engine (JWT)](#kv-secrets-engine-jwt)
  - [Database Secrets Engine (PostgreSQL)](#database-secrets-engine-postgresql)
- [Authentication & Access Control](#authentication--access-control)
  - [Policies](#policies)
  - [AppRole Setup](#enable-approle-authentication)
- [Next Steps](#next-steps)
- [Troubleshooting](#troubleshooting)

---

## 📦 Prerequisites

Choose **one** of the following deployment methods:

- **Local installation**: Download and install HashiCorp Vault (see [Linux installation guide](https://developer.hashicorp.com/vault/install#linux)).
- **Container setup** (recommended): Use Docker and Docker Compose with the OpenBAO image.

This guide assumes **Docker Compose**. Adjust commands if using a local Vault installation.

---

## 🏗️ Vault Deployment

### Directory Setup

Create a dedicated directory structure to organize Vault data, configuration, policies, and TLS certificates:

```bash
/var/lib/containers-data/vault/
├── config/       # Vault server configuration (vault.hcl, policies/)
├── data/         # Persistent storage for Raft backend
├── home/         # Home directory for vault user
└── logs/         # Application logs
```

Run these commands to create and configure the directory:

```bash
# Create directories
sudo mkdir -p /var/lib/containers-data/vault/data
sudo mkdir -p /var/lib/containers-data/vault/config
sudo mkdir -p /var/lib/containers-data/vault/config/policies
sudo mkdir -p /var/lib/containers-data/vault/home

# Set ownership and permissions (for container user 1000:1000)
sudo chown -R 1000:1000 /var/lib/containers-data/vault
sudo chmod -R 750 /var/lib/containers-data/vault
```

---

### Configuration File

Create a **Vault configuration file** at `/var/lib/containers-data/vault/config/config.hcl`:

```hcl
# Storage backend: uses local Raft consensus for high availability
storage "raft" {
  path    = "/var/lib/containers-data/vault/data"
  node_id = "node1"
}

# Network listener: accepts client connections
listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = "true"   # TESTING ONLY: enable TLS in production
}

# API address that clients use to connect to Vault
api_addr = "http://vault:8200"

# Cluster address for inter-node communication
cluster_addr = "http://vault:8201"

# Memory locking disabled for container environments
disable_mlock = true

# Enable the web UI for manual operations
ui = true
```

**Configuration Explanation:**

| Setting | Purpose |
|---------|---------|
| `storage "raft"` | Uses Raft consensus for distributed, replicated storage. Alternative: `storage "file"` for single-node. |
| `listener "tcp"` | Network listener on port 8200. Set `tls_disable = "false"` and add certificates in production. |
| `api_addr` | Public address clients use; must be reachable from outside the container. |
| `cluster_addr` | Address for cluster peer communication (port 8201). |
| `ui = true` | Enables the built-in Vault web dashboard at `http://vault:8200/ui/`. |

---

### Docker Compose & Startup

Create or update your `docker-compose.yml` to include the Vault service:

```yaml
services:
  # --- Ngelmak Vault Service ---
  vault:
    image: openbao/openbao:latest
    container_name: vault
    user: "1000:1000"
    ports:
      - "8200:8200"      # Web UI & API
      - "8201:8201"      # Cluster communication
    volumes:
      - /var/lib/containers-data/vault/data:/data
      - /var/lib/containers-data/vault/config:/etc/openbao
      - /var/lib/containers-data/vault/home:/home/vault
    environment:
      HOME: /home/vault
      VAULT_ADDR: "http://127.0.0.1:8200"
    command: server -config=/etc/openbao/config.hcl
    networks:
      - ngelmak-net
    restart: unless-stopped

networks:
  ngelmak-net:
    driver: bridge
```

Start Vault:

```bash
docker compose up -d vault
```

Access the Vault shell for CLI commands:

```bash
docker exec -it vault sh
```

Inside the container, export the Vault address so the CLI client knows where to connect:

```bash
export VAULT_ADDR=http://127.0.0.1:8200
```

> ⚠️ **Common Error**: If you see `http: server gave HTTP response to HTTPS client`, you likely forgot to set `VAULT_ADDR=http://...` (without HTTPS).

---

### Initialization & Unsealing

#### Initialize Vault

**Initialization** generates the unseal keys and root token. Run this **once**:

```bash
vault operator init -key-shares=5 -key-threshold=3
```

**Parameters:**

| Parameter | Meaning |
|-----------|---------|
| `-key-shares=5` | Generate 5 unseal keys total. |
| `-key-threshold=3` | Require 3 of the 5 keys to unseal Vault (Shamir secret sharing). |

**Expected output:**

```
Unseal Key 1: bOFCovW3pIIsTWwwLr8OrewWdRa2dIAMWtiY4Z3qqboK
Unseal Key 2: Mh1UBeRIw0pPY0bbU8k5uhGPsGxBSIJwtRQ0Rz7knsTw
Unseal Key 3: 1wQRrS8SHTtIvs+dIBH5qLb2DNmo/st8vDfDTbXdW6xV
Unseal Key 4: VHsfgOSezBe12es8IEN9cJygeJE+L6eewqpRhQHFVJ0L
Unseal Key 5: yJvW2edKatEYUYbmjjWL41eW2qrPFqSbCS3xYLTbVJwj

Initial Root Token: s.bahXTSn2G7jdRVM3Tc62kR0a
```

> ⚠️ **CRITICAL**: Store unseal keys securely. Do **not** commit them to Git or share them in chat. Use an HSM, encrypted vault, or secure secret manager (e.g., 1Password, LastPass, AWS Secrets Manager).

#### Unseal Vault

Provide **3 of the 5** unseal keys to unlock Vault. You can use the CLI or the web UI at `http://localhost:8200/ui/`:

**Via CLI:**

```bash
vault operator unseal <unseal-key-1>
vault operator unseal <unseal-key-2>
vault operator unseal <unseal-key-3>
```

**Expected output after the third key:**

```
Key                     Value
---                     -----
Seal Type               shamir
Initialized             true
Sealed                  false
Total Shares            5
Threshold               3
Version                 1.x.x
...
```

Once `Sealed = false`, Vault is ready for use.

---

### Secure the Root Token

The root token has unlimited access. Use it **only** for initial setup, then revoke it immediately.

#### Login with Root Token

```bash
vault login
```

Enter the root token when prompted. Success output:

```
Success! You are now authenticated. The token information displayed below is
already stored in the token helper. You do NOT need to run "vault login" again.
Future OpenBao requests will automatically use this token.

Key                  Value
---                  -----
token                s.bahXTSn2G7jdRVM3Tc62kR0a
token_accessor       A1B2C3D4E5F6G7H8
token_duration       ∞
token_renewable      false
token_policies       ["root"]
identity_policies    []
policies             ["root"]
```

> **Best Practice**: After completing all setup steps below (enabling engines, creating policies, and AppRoles), revoke the root token to minimize exposure:
> ```bash
> vault token revoke -self
> ```

---

## 💾 Secrets Configuration

### KV Secrets Engine (JWT)

The **KV (Key-Value) secrets engine** stores static secrets like your JWT signing key.

#### Enable KV Engine

```bash
vault secrets enable -path=secret kv

Success! Enabled the kv secrets engine at: secret/
```

#### Store the JWT Secret

```bash
vault kv put secret/jjwt jwt-secret-key="super-secret-key-change-this"
```

- **secret/jjwt** → path where the secret is stored.
- **jwt-secret-key** → field name.
- **"super-secret-key-change-this"** → the actual secret (replace with a strong value).

#### Retrieve the Secret

Verify the secret is stored:

```bash
vault kv get secret/jjwt

====== Data ======
Key                 Value
---                 -----
jwt-secret-key      super-secret-key-change-this
```

---

### Database Secrets Engine (PostgreSQL)

The **Database secrets engine** dynamically generates temporary PostgreSQL credentials with automatic rotation and expiration. This eliminates hardcoded database passwords.

#### Prerequisites

- **PostgreSQL** installed and running (reachable from the Vault container).
- A superuser account for Vault to manage credentials.

#### Create PostgreSQL Roles & Database

Connect to PostgreSQL and run these SQL commands:

```sql
-- Create Vault admin role (superuser)
CREATE ROLE vaultadmin WITH LOGIN SUPERUSER PASSWORD 'vaultpassword';

-- Create the application database
CREATE DATABASE ngelmakdb OWNER vaultadmin;
```

> **Security Note**: Change `'vaultpassword'` to strong, unique values. In production, also consider using certificates instead of passwords.

#### Enable Database Engine

```bash
vault secrets enable database

Success! Enabled the database secrets engine at: database/
```

#### Configure Vault-PostgreSQL Connection

Tell Vault how to connect to your PostgreSQL instance:

```bash
vault write database/config/ngelmak-postgres-database \
  plugin_name=postgresql-database-plugin \
  connection_url="postgresql://{{username}}:{{password}}@postgres:5432/ngelmakdb" \
  username="vaultadmin" \
  password="vaultpassword" \
  allowed_roles="ngelmak-springboot-role" \
  rotation_window="1h" \
  rotation_schedule="0 * * * SAT"

Success! Data written to: database/config/ngelmak-postgres-database
```

**Parameter Explanation:**

| Parameter | Purpose |
|-----------|---------|
| `plugin_name` | Database driver; use `postgresql-database-plugin` for PostgreSQL. |
| `connection_url` | Template URL with placeholders for `{{username}}` and `{{password}}`; Vault injects credentials. Host `postgres` assumes Docker service name. |
| `username` / `password` | Superuser credentials Vault uses to create/revoke dynamic users. |
| `allowed_roles` | Comma-separated list of Vault roles permitted to request credentials from this config. |
| `rotation_window` | Time window for credential rotation (optional). |
| `rotation_schedule` | Cron-style schedule to rotate root credentials; `"0 * * * SAT"` = every Saturday at midnight. |

#### Define a Role for Dynamic Credentials

Create a Vault role that maps to an SQL template for generating users:

```bash
vault write database/roles/ngelmak-springboot-role \
  db_name=ngelmak-postgres-database \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';" \
  default_ttl="48h" \
  max_ttl="72h"

Success! Data written to: database/roles/ngelmak-springboot-role
```

**Parameter Explanation:**

| Parameter | Purpose |
|-----------|---------|
| `db_name` | Links to the database config created above (`ngelmak-postgres-database`). |
| `creation_statements` | SQL template Vault executes to create users. Vault injects `{{name}}` (username), `{{password}}`, and `{{expiration}}`. |
| `default_ttl` | Default lifetime of generated credentials (e.g., 48 hours). |
| `max_ttl` | Maximum lifetime; credentials cannot be renewed beyond this limit (e.g., 72 hours). |

#### Request Dynamic Credentials (Example)

Once configured, your Spring Boot app (authenticated via AppRole) can request credentials:

```bash
vault read database/creds/ngelmak-springboot-role

Key                Value
---                -----
lease_id           database/creds/ngelmak-springboot-role/AB1CD2EF3
lease_duration     48h
lease_renewable    true
password           xxxxxxxxxxx
username           v_ngelmak_springboot_r_AbCdEfGhIjK
```

The temporary user `v_ngelmak_springboot_r_AbCdEfGhIjK` is valid for 48 hours, then automatically revoked.

---

## 🔐 Authentication & Access Control

### Policies

**Policies** define what secrets each application or user can access. They restrict access to specific paths and operations.

#### Create a Policy File

Create `/var/lib/containers-data/vault/config/policies/ngelmak-springboot-policy.hcl`:

```hcl
# Allow reading the JWT secret
path "secret/data/jjwt" {
  capabilities = ["read"]
}

# Allow reading dynamic PostgreSQL credentials
path "database/creds/ngelmak-springboot-role" {
  capabilities = ["read"]
}
```

**Path Explanation:**

| Path | Purpose |
|------|---------|
| `secret/data/jjwt` | KV v2 API path for reading the JWT secret. (Note: KV v2 uses `data/` in the path.) |
| `database/creds/ngelmak-springboot-role` | Database engine path for requesting dynamic credentials. |

**Capabilities:**

- `read` → retrieve secrets.
- `create` / `update` → write or modify data.
- `delete` → remove data.
- `list` → enumerate paths.

#### Load the Policy

```bash
vault policy write ngelmak-springboot-policy \
  /etc/openbao/policies/ngelmak-springboot-policy.hcl

Success! Uploaded policy: ngelmak-springboot-policy
```

Verify the policy was loaded:

```bash
vault policy read ngelmak-springboot-policy
```

---

### Enable AppRole Authentication

**AppRole** is an authentication method designed for applications and automated workflows. It uses two pieces of information:

1. **Role ID** → a non-secret identifier.
2. **Secret ID** → a secret credential (rotated frequently).

#### Enable AppRole

```bash
vault auth enable approle

Success! Enabled approle auth method at: approle/
```

#### Create an AppRole

```bash
vault write auth/approle/role/springboot \
  policies="ngelmak-springboot-policy" \
  secret_id_ttl=72h \
  token_ttl=24h \
  token_max_ttl=48h

Success! Data written to: auth/approle/role/springboot
```


**Parameter Explanation:**

| Parameter | Purpose |
|-----------|---------|
| `policies` | Attach the policy created above; defines what the app can access. |
| `secret_id_ttl` | Time-to-live for Secret IDs (72 hours); they expire and must be rotated. |
| `token_ttl` | Default lifetime of Vault tokens issued to the app (24 hours). |
| `token_max_ttl` | Maximum lifetime; tokens cannot be renewed beyond this limit (48 hours). |

#### Retrieve the Role ID

The **Role ID** is a non-secret identifier you can safely share with your app:

```bash
vault read auth/approle/role/springboot/role-id

Key        Value
---        -----
role_id    c481309c-8927-83b8-92a3-771d312e4905
```

Save this Role ID in your app's configuration (e.g., `application.yml`).

#### Generate a Secret ID

The **Secret ID** is the secret half of the AppRole credential. Generate one:

```bash
vault write -f auth/approle/role/springboot/secret-id

Key                   Value
---                   -----
secret_id             c78ee677-3b49-e5a8-9b91-810c1d768fa9
secret_id_accessor    c190bdb7-5a4f-b4f5-abe0-06437f17ee6b
secret_id_num_uses    0
secret_id_ttl         72h
```

> ⚠️ **Important**: The Secret ID is sensitive. Store it securely (e.g., environment variable, secrets file, or secure vault). Do **not** commit it to Git. Rotate Secret IDs regularly before they expire (72 hours).

#### AppRole Login Flow

Your Spring Boot app authenticates using the **Role ID** and **Secret ID**:

```bash
# Example: AppRole login (your app does this automatically)
vault write auth/approle/login \
  role_id="c481309c-8927-83b8-92a3-771d312e4905" \
  secret_id="c78ee677-3b49-e5a8-9b91-810c1d768fa9"

Key                     Value
---                     -----
token                   s.xxxxxxxxxxxxxx
token_accessor          1234567890abcdef
token_duration          24h
token_renewable         true
token_policies          ["ngelmak-springboot-policy"]
identity_policies       []
policies                ["ngelmak-springboot-policy"]
```

Vault returns a **token** valid for 24 hours. Your app uses this token to request secrets.

---

## 🚀 Next Steps

### 1. Integrate with Spring Boot

Configure your Spring Boot application to authenticate via AppRole and retrieve secrets from Vault. Use the **Spring Cloud Vault** library:

**Add dependency** (`pom.xml`):

```xml
<dependency>
  <groupId>org.springframework.cloud</groupId>
  <artifactId>spring-cloud-starter-vault-config</artifactId>
  <version>4.0.0</version>
</dependency>
```

**Configure** (`application.yml`):

```yaml
spring:
  cloud:
    vault:
      host: vault                          # Docker service name or IP
      port: 8200
      scheme: http                         # Use https in production
      authentication: APPROLE
      app-role:
        role-id: c481309c-8927-83b8-92a3-771d312e4905
        secret-id: c78ee677-3b49-e5a8-9b91-810c1d768fa9
      kv:
        enabled: true
        backend: secret
      generic:
        enabled: true
```

**Access secrets in code**:

```java
@Configuration
public class VaultConfig {
  
  @Value("${jjwt:jwt-secret-key}")
  private String jwtSecretKey;
  
  @Bean
  public JwtTokenProvider jwtTokenProvider() {
    return new JwtTokenProvider(jwtSecretKey);
  }
}
```

### 2. Database Connection with Dynamic Credentials

Spring Boot can automatically fetch and refresh dynamic database credentials:

```yaml
spring:
  datasource:
    url: jdbc:postgresql://postgres:5432/ngelmakdb
    username: ${vault.postgresql.username}
    password: ${vault.postgresql.password}
  jpa:
    hibernate:
      ddl-auto: validate
```

Vault automatically rotates credentials before expiration; Spring Boot refreshes its connection pool.

### 3. Rotate Secret IDs

Before the Secret ID expires (72 hours), generate a new one and update your app:

```bash
# Generate a new Secret ID
vault write -f auth/approle/role/springboot/secret-id

# Delete the old Secret ID (optional, but recommended)
vault write auth/approle/role/springboot/secret-id/destroy \
  secret_id="c78ee677-3b49-e5a8-9b91-810c1d768fa9"
```

### 4. Monitor and Audit

Enable audit logging to track all Vault access:

```bash
vault audit enable file file_path=/var/lib/containers-data/vault/logs/audit.log
```

View audit logs:

```bash
vault audit list
```

---

## 🔧 Troubleshooting

### Error: "http: server gave HTTP response to HTTPS client"

**Cause**: The Vault client is trying to connect via HTTPS, but Vault is configured for HTTP.

**Solution**: Ensure you set the correct environment variable inside the container:

```bash
export VAULT_ADDR=http://127.0.0.1:8200
```

(Note: `http://`, not `https://`)

---

### Error: "permission denied" when creating directories

**Cause**: Insufficient permissions on `/var/lib/containers-data/vault`.

**Solution**: Run the directory setup commands with `sudo`:

```bash
sudo chown -R 1000:1000 /var/lib/containers-data/vault
sudo chmod -R 750 /var/lib/containers-data/vault
```

---

### Error: "Vault is sealed" when running commands

**Cause**: Vault was restarted and needs to be unsealed again.

**Solution**: Use the web UI (`http://localhost:8200/ui/`) or provide unseal keys via CLI:

```bash
vault operator unseal <key-1>
vault operator unseal <key-2>
vault operator unseal <key-3>
```

---

### Error: "connection refused" when connecting to PostgreSQL

**Cause**: Vault cannot reach the PostgreSQL service (wrong hostname, port, or service not running).

**Solution**:

1. Verify PostgreSQL is running and reachable from the Vault container:
   ```bash
   docker exec vault nc -zv postgres 5432
   ```

2. Check the `connection_url` in your database config uses the correct service name (e.g., `postgres` if using Docker Compose).

3. Verify firewall rules allow traffic on port 5432.

---

### Error: "role_id mismatch" during AppRole login

**Cause**: The Role ID provided doesn't match a configured AppRole.

**Solution**: Double-check the Role ID:

```bash
vault read auth/approle/role/springboot/role-id
```

Ensure your app is using the **exact** Role ID returned.

---

### Error: "secret_id expired" when the app tries to authenticate

**Cause**: The Secret ID's TTL (72 hours) has elapsed.

**Solution**: Generate a new Secret ID and update your app's configuration:

```bash
vault write -f auth/approle/role/springboot/secret-id
```

---

### Verify Vault Is Running

Check the container is healthy:

```bash
docker ps | grep vault
```

View Vault logs:

```bash
docker logs vault
```

Verify connectivity from inside the container:

```bash
docker exec vault curl -s http://127.0.0.1:8200/v1/sys/seal-status | jq .
```

Expected output shows `"sealed": false`.

---

## ✅ Summary & Architecture

Here's the complete authentication and secret-retrieval flow:

```
┌─────────────────────┐
│  Spring Boot App    │
│  (ngelmak-project)  │
└──────────┬──────────┘
           │
           │ 1. Authenticate with Role ID + Secret ID
           ↓
┌──────────────────────────┐
│   OpenBAO Vault          │
│  - AppRole Auth Method   │
│  - Issues Vault Token    │
└──────────┬───────────────┘
           │
           │ 2. Token + Policy (ngelmak-springboot-policy)
           │
    ┌──────┴────────┬────────────┐
    ↓               ↓            ↓
┌────────┐    ┌─────────────┐  ┌────────────┐
│ KV     │    │ Database    │  │ Transit    │
│Engine  │    │ Engine      │  │ (optional) │
├────────┤    ├─────────────┤  └────────────┘
│JWT Key │    │ Postgres    │
│secret/ │    │ Creds       │
│jjwt    │    │ database/   │
│        │    │ creds/...   │
└────────┘    └─────────────┘
    ↓              ↓
[Return]      [Temporary Creds]
JWT Key       (auto-rotate)
```

**Key Points:**

- **Initialization**: Done once; generates unseal keys and root token.
- **Unsealing**: Required after Vault restart; uses 3 of 5 unseal keys.
- **Policies**: Restrict app access to only required paths.
- **AppRole**: Authenticates the app; issues short-lived tokens.
- **KV Engine**: Stores static secrets (JWT).
- **Database Engine**: Generates dynamic, auto-rotating credentials.
- **Token Rotation**: Vault tokens expire; apps must re-authenticate.
- **Secret ID Rotation**: Regenerate Secret IDs before expiration (72 hours).

---

## 📚 Additional Resources

- **Official Vault Documentation**: https://www.vaultproject.io/docs
- **OpenBAO (Open-source fork)**: https://openbao.org
- **Spring Cloud Vault**: https://spring.io/projects/spring-cloud-vault
- **Vault API Reference**: https://www.vaultproject.io/api-docs
- **AppRole Auth Method**: https://www.vaultproject.io/docs/auth/approle