# CloudNativePG

## Adding an application

1. Add a role under `spec.managed.roles` in `cluster.yaml`
2. Add a `Database` in `cluster.yaml` owned by the previously added role
3. Add an `ensure_role_secret` line in `apply.sh`

## Known limitations

**Every role can connect to every database**: Postgres grants `CONNECT` to
`PUBLIC` by default. For example, `gitea` can open a connection to `portfolio`,
though it cannot read its tables.

Fix from the psql:

```psql
revoke connect on database gitea from public;
grant connect on database gitea to gitea;
```
