# Contributing

Docker images for running Homebridge (a fork of homebridge/docker-homebridge).

Bug reports and feature requests are welcome as [issues](https://github.com/maubergine/docker-homebridge/issues). Pull requests are
welcome too; CI on a pull request from a fork may wait for the maintainer to approve it.

## Commits

Use [Conventional Commits](https://www.conventionalcommits.org/): `fix:`, `feat:`, `chore:`, `docs:` and so on. This fork doesn't use semantic-release, so commits don't cut releases. CI checks
every commit (`commitlint.yml`). To check them locally before you push:

```sh
npm install   # installs commitlint and turns on .githooks/commit-msg
```

Commits to `latest` must be signed.

## Tests

Run `shellcheck -S error` on the shell scripts and build the image with Docker (see `ci.yml`).
