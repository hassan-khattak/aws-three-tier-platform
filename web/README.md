# Devops Web App


### install the node packages for the web tier:
```sh
→ npm install
```
### start the app
```sh
→ npm start
```

###  NOTE this app uses two env variables:

- PORT: the listening PORT
- API_HOST: the base url of the API app, without `/api` (for example `http://localhost:3001`); `/api/status` is appended

These two variables need to be set. See `.env.example` and [the application contract](../docs/contracts/application.md) for validation rules, health endpoints and shutdown behavior. 
