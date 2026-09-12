# Containers, CI and deployment

## Local evaluation

Requirements: Docker Engine/Desktop and Docker Compose v2 or newer. No host Ruby,
Node.js, database, or API key is required for this non-commercial demo.

```sh
docker compose up --build --wait
```

Open http://localhost:3001. Port 3001 avoids conflicting with a host Rails server
on 3000. Override with `WEB_PORT=3000 docker compose up --build --wait`.
Compose runs development mode, without production secrets or HTTPS requirements,
and binds only to localhost. It packages source into the image: rebuild after
editing files. There are no source bind mounts or persistent volumes.

```sh
docker compose logs -f web
docker compose run --rm -e RAILS_ENV=test web bin/rails test
docker compose down
```

## CI on any Docker-capable runner

```sh
bin/docker-ci
```

This builds the test target, runs the suite, RuboCop and Brakeman without network
access, builds the production image, and checks health, HTML, compiled CSS,
non-root execution and absence of the local master key. It removes its own
smoke-test container on exit. The script does not publish images or deploy.
The GitHub Actions Docker workflow runs this same script on Linux/amd64.
Dependency vulnerability auditing remains in the existing CI workflow and needs
network access to maintain its advisory database.

The first build downloads the base image, OS packages and locked gems. Runtime
weather lookups require HTTPS egress to Census and Open-Meteo (weather and geocoding). Tests mock those APIs.

## Production image

```sh
docker build --target production -t weather-forecast:release .
```

The default final target is production. The multi-stage build keeps compilers
and development/test gems out of the runtime, precompiles assets without a real
secret, and runs Puma as UID/GID 1000. Ruby is fixed to 4.0.6; Bundler is selected
from Gemfile.lock. Tags may receive upstream security updates; for strictly
immutable releases pin the approved base-image manifest digest as well.

The runtime contract is independent of the deployment provider:

| Setting | Contract |
| --- | --- |
| `SECRET_KEY_BASE` | Required runtime secret; stable across restarts and replicas |
| `PORT` | Listening port, default 3000; Puma binds to 0.0.0.0 |
| `RAILS_FORCE_SSL` | Defaults to true; production should retain HTTPS enforcement |
| `RAILS_ASSUME_SSL` | Defaults to true; assumes a trusted TLS-terminating proxy |
| `RAILS_LOG_LEVEL` | Defaults to info; logs go to stdout |
| `RAILS_MAX_THREADS` | Defaults to 3 |
| `/up` | HTTP 200 health endpoint, exempt from HTTPS redirects |

Generate a secret with `openssl rand -hex 64` and store it in the deployment
platform's secret manager. Inject it at runtime; never use a build argument,
commit it, or reuse the CI smoke-test key. The image excludes local encrypted
credentials and keys; this application uses environment configuration.

Example with SECRET_KEY_BASE already exported by the secret manager:

```sh
docker run --rm -p 127.0.0.1:3000:3000 \
  -e SECRET_KEY_BASE weather-forecast:release
```

Production expects TLS termination in front of Puma. For a local-only production
smoke test, additionally set both SSL flags to false; bin/docker-ci does this in
an isolated container with no published ports. Do not copy that override into
an internet-facing deployment. Allow a graceful shutdown period of at least
30 seconds. No database migrations or release tasks are required.

The same Dockerfile can target linux/amd64 or linux/arm64 with Buildx. To publish,
configure registry credentials in CI and use an immutable commit/release tag.
Deployment credentials, registry destination and provider-specific rollout steps
must be configured for the chosen platform; no deployment is configured here.

## Operational limits

The weather cache is in-process memory and disappears on restart. Use one Puma
process and one replica for shared ZIP reuse within this demo. Multiple replicas
are possible but have independent caches. Before scaling, choose and configure
a shared cache if all instances must reuse forecasts. Docker does not change
this behavior. The free weather endpoint assumes non-commercial use; review
provider licensing before a commercial deployment.

References: [Docker build practices](https://docs.docker.com/build/building/best-practices/),
[Rails asset precompilation](https://guides.rubyonrails.org/asset_pipeline.html).
