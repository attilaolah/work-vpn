# OpenVPN 4 Work

This repo contains a Nix flake for seamlessly connecting to an OpenVPN server
using credentials stored in BitWarden. All dependencies, including the OpenVPN
and the BitWarden CLI, are flake dependencies; to use it, simply add this flake
to your flake inputs.

The script exports a binary called `work-vpn` in its default package, which
depends on a few environment variables:

- `BW_SESSION`: A BitWarden Session key, which can be obtained by running `bw
  login`.
- `OPENVPN_BW_ID`: The ID of the BitWarden secret in which the credentials are
  stored.
- `OPENVPN_URL`: URL of the OpenVPN server to connect to.
- `OPENVPN_URL_STAGE`: Alternative URL to connect to when using the `-s` or
  `--staging` flag.
- `OPENVPN_CHALLENGE_PREFIX`: Custom prefix used in every 2nd factor challenge
  response. May be set to an empty string if not required.

The following credentials need to be stored in the BitWarden item:

- `username`: OpenVPN username.
- `password`: OpenVPN password.
- Custom fields:
  - `openvpn_ca`: CA (Certificae Authority) used to authenticate the server.
  - `openvpn_tls_client_key`: TLS Client Key used for post-quantum encryption.

The CA & TLS client key should be in PEM format, _without_ the surrounding
BEGIN/END blocks, and newlines may be replaced by spaces to accomodate
BitWarden UI limitations.

A convenient way to store these environment variables is by using [direnv].
Workspace-specific values can be put in `.envrc`, along with the line
`dotenv_if_exists .env.local`, while putting user-specific values into
`.env.local`. For example:

[direnv]: https://direnv.net

### `.envrc`

```sh
export OPENVPN_URL=openvpn.example.com
export OPENVPN_URL_STAGE=openvpn-stage.example.com
dotenv_if_exists .env.local
```

### `.env.local`

```sh
export BW_SESSION=...
export OPENVPN_BW_ID=...
export OPENVPN_CHALLENGE_PREFIX=...
```
