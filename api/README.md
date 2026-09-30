# Devops API App

## install the node packages for the api tier:

```sh
→ npm install
```

## start the app

```sh
→ npm start
```

## NOTE this app uses these env variables:

- PORT: the listening PORT
- DB: Name of the database to connect
- DBUSER: Database user
- DBPASS: DB user password,
- DBHOST: Database hostname,
- DBPORT: Database server listening port
- DB_SSL: `true` (default, required in production) or `false` for a local database
- DB_CA_FILE: CA bundle used to verify the database certificate when DB_SSL is true

These variables need to be set. See `.env.example` and [the application contract](../docs/contracts/application.md) for validation rules, endpoints (`/api/status`, `/health/live`, `/health/ready`) and shutdown behavior.
