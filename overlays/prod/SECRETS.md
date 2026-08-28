# Secrets & the orangeexpress.in cutover

The backend used to carry its JWT secret and Razorpay keys as plaintext `value:`
entries in `base/backend-deployment.yaml`, in a **public** repository. They now
come from a Secret named `orangy-secrets`, created per namespace and never
committed.

> **Treat every previously committed value as leaked — some are live.**
> They are in public git history permanently. Deleting them from the files does
> not remove them from history.
>
> Revoke and rotate, in this order of urgency:
>
> 1. **Gmail app password** `gddu hlzk lkhh yten` for `khursangevedant@gmail.com`,
>    which was hardcoded as the default in `application.yml` in the public
>    `Orangy` repo. Revoke it at <https://myaccount.google.com/apppasswords> and
>    issue a new one. This grants send-as access to a personal mailbox.
> 2. **The seeded admin account.** `DataSeeder` hardcoded
>    `admin@orangy.com` / `admin123` and created it on every boot, so any
>    deployed environment has an admin with publicly known credentials. Change
>    that password (or delete the row) in each environment's database now.
> 3. **Razorpay test key pair** — rotate in the Razorpay dashboard.
> 4. **JWT signing secret** — generate a fresh one per environment. Rotating it
>    invalidates existing sessions, which is expected.

## Order matters

`orangy-dev` is **auto-synced** by ArgoCD, so the moment these manifests land on
`main`, dev re-renders and its backend will `CreateContainerConfigError` until
`orangy-secrets` exists in that namespace. Create the Secrets **first**, then
push.

`orangy-prod` is manual-sync, so prod only changes when you click Sync.

## 1. Create the Secret in both namespaces

Generate a fresh JWT secret (HS256 needs >= 256 bits):

```bash
openssl rand -base64 48
```

Then, substituting your own values:

```bash
kubectl -n orangy-dev create secret generic orangy-secrets \
  --from-literal=jwt-secret='<fresh-random-secret>' \
  --from-literal=razorpay-key-id='<rzp_test_...>' \
  --from-literal=razorpay-key-secret='<rotated-test-secret>' \
  --from-literal=mail-username='<gmail-address>' \
  --from-literal=mail-password='<NEW-gmail-app-password>' \
  --from-literal=cloudflared-token=''
```

```bash
kubectl -n orangy-prod create secret generic orangy-secrets \
  --from-literal=jwt-secret='<different-fresh-random-secret>' \
  --from-literal=razorpay-key-id='<rzp_test_...>' \
  --from-literal=razorpay-key-secret='<rotated-test-secret>' \
  --from-literal=mail-username='<gmail-address>' \
  --from-literal=mail-password='<NEW-gmail-app-password>' \
  --from-literal=cloudflared-token='<tunnel-token-from-step-2>'
```

`mail-username` / `mail-password` are **required** — OTP sign-in is delivered
over SMTP, so the backend will not start without them. That is deliberate: a
missing value fails the rollout instead of silently breaking every login.

`admin-email` / `admin-password` are optional and only needed on a fresh
database. Add them with `kubectl edit secret` if you ever need the seeder to
create an admin; the seeder refuses passwords under 12 characters.

Use a **different** JWT secret per environment; a shared one means a dev token
is valid in prod. Rotating it invalidates existing sessions, which is expected.

## 2. Create the Cloudflare Tunnel

In the Cloudflare dashboard: **Zero Trust → Networks → Tunnels → Create tunnel**
(name it `orangeexpress-prod`). Copy the token it shows and put it in the prod
Secret above as `cloudflared-token`.

Then add a **public hostname** on that tunnel:

| Field | Value |
|---|---|
| Subdomain | *(blank)* |
| Domain | `orangeexpress.in` |
| Service type | HTTP |
| URL | `frontend:80` |

Repeat for `www` if you want it, or add a Cloudflare redirect rule sending
`www` → apex.

Cloudflare creates the DNS record for you — do **not** add an A record to the
node's IP. The tunnel dials outbound, so nothing needs opening in the Oracle
security list, and the node's IP stays private.

### Why a tunnel and not an A record

Cloudflare's proxy only accepts a fixed set of ports (80, 443, 8080, 8443, …).
The prod frontend is a NodePort on **30301**, which is not in that set, so a
proxied A record to `node-ip:30301` cannot work. Un-proxying it would expose the
node's IP directly and give up TLS termination.

## 3. Set TLS mode

Cloudflare → SSL/TLS → set encryption mode to **Full**. The tunnel carries
traffic to the cluster, so the browser gets a valid Cloudflare edge certificate.
Enable **Always Use HTTPS**.

## 4. Sync prod

```bash
argocd app sync orangy-prod
```

Watch the rollout — the backend now starts under the `prod` Spring profile for
the first time:

```bash
kubectl -n orangy-prod get pods -w
kubectl -n orangy-prod logs deploy/backend --tail=100
kubectl -n orangy-prod logs deploy/cloudflared --tail=50
```

## Still outstanding

- **`SPRING_JPA_HIBERNATE_DDL_AUTO=update`** — Hibernate mutates the live schema
  on every boot. `application-prod.yml` already asks for `validate`, but the
  base env var overrides it. Flipping it needs a real migration tool (Flyway or
  Liquibase) first, or prod will fail to start whenever the mapping and schema
  disagree. This is the single biggest remaining data risk.
- **No database backups.** Postgres is a 1Gi PVC on a single node with no
  snapshot or dump schedule. An order database needs at least a nightly
  `pg_dump` to object storage.
- **Postgres password is `postgres`**, cluster-internal only. Changing it needs
  a DB-side `ALTER USER`, since `POSTGRES_PASSWORD` only applies at first init.
- **Razorpay is still in test mode.** Live keys require KYC activation, and go
  in this Secret — never in git.
- **Single node**, so there is no real availability guarantee.
