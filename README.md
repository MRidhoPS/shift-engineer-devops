# Shift Engineer DevOps: Binary Hotfix Without Rebuilding or Restarting the Container

A small Go service with two goals:

1. **Part 1:** ship a new version by replacing only the binary. The Docker image is not rebuilt and the container is neither restarted nor recreated.
2. **Part 2:** drive the whole flow from a Jenkins pipeline (checkout, test, build image, push, deploy).

## 1. Repository layout

```
.
├── Dockerfile               # application image (multi-stage, alpine runtime)
├── entrypoint.sh            # in-container supervisor that reloads the app when the binary changes
├── Jenkinsfile              # CI/CD pipeline
├── .gitattributes           # forces LF line endings for *.sh
├── cmd/
│   ├── server/main.go       # entrypoint, holds the injected `version` variable
│   └── internal/server/     # handlers and tests
├── scripts/
│   ├── build-binary.sh      # builds a Linux binary, auto-increments the version
│   ├── hotfix.sh            # backup, atomic replace, health check, auto-rollback
│   └── rollback.sh          # manual rollback from a backup file
└── jenkins/Dockerfile       # Jenkins image with Go and Docker CLI
```

---

## 2. Part 1: Binary hotfix

### 2.1 Dockerfile

Multi-stage build. The Go toolchain lives only in the builder stage. The runtime image contains the static binary and a tiny supervisor script.

```dockerfile
FROM golang:1.27-alpine AS builder

WORKDIR /src

COPY go.mod go.sum* ./
RUN go mod download

COPY . .

ARG VERSION=dev

RUN CGO_ENABLED=0 \
    GOOS=linux \
    GOARCH=amd64 \
    go build \
    -trimpath \
    -ldflags="-s -w -X main.version=${VERSION}" \
    -o /out/server \
    ./cmd/server

FROM alpine:3.20

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

COPY --from=builder /out/server /app/server

EXPOSE 8080

ENTRYPOINT ["/entrypoint.sh"]
```

`entrypoint.sh` is PID 1 inside the container. It starts `/app/server`, checks its hash every second, and restarts **only the application process** when the file changes:

```sh
#!/bin/sh

APP=/app/server
PID=""
LAST=""

hash_app() {
    md5sum "$APP" 2>/dev/null | cut -d' ' -f1
}

start_app() {
    "$APP" &
    PID=$!
    LAST="$(hash_app)"
    echo "supervisor: started ${APP} pid=${PID} hash=${LAST}"
}

stop_app() {
    if [ -n "$PID" ]; then
        kill "$PID" 2>/dev/null
        wait "$PID" 2>/dev/null
    fi
}

trap 'stop_app; exit 0' TERM INT

start_app

while true; do
    sleep 1
    CUR="$(hash_app)"
    if [ -n "$CUR" ] && [ "$CUR" != "$LAST" ]; then
        echo "supervisor: binary changed, reloading process"
        stop_app
        start_app
    elif ! kill -0 "$PID" 2>/dev/null; then
        echo "supervisor: app exited, restarting process"
        start_app
    fi
done
```

### 2.2 Build command

Initial image (built once):

```bash
docker build -t shift-engineer-devops:bootstrap --build-arg VERSION=v0 .
```

Image built by the pipeline (version = build number + short commit hash, injected via `-ldflags "-X main.version=..."`):

```bash
docker build \
  --build-arg VERSION="v<BUILD_NUMBER>-<git-short-sha>" \
  --label org.opencontainers.image.revision="<git-short-sha>" \
  --label org.opencontainers.image.version="v<BUILD_NUMBER>-<git-short-sha>" \
  -t shift-engineer-devops:v<BUILD_NUMBER>-<git-short-sha> \
  -t shift-engineer-devops:latest \
  .
```

### 2.3 Final image size

```
$ docker images shift-engineer-devops
REPOSITORY              TAG         IMAGE ID       CREATED         SIZE
<paste the output of your own `docker images shift-engineer-devops` here>
```

**Why this size:**

- The multi-stage build discards the builder stage, so the Go toolchain (hundreds of MB) never reaches the final image.
- The runtime image is `alpine:3.20` (about 8 MB) plus the static binary (about 5.6 MB) plus a tiny shell script, so roughly 13 to 14 MB in total.
- The binary is small because it is built with `CGO_ENABLED=0`, `-trimpath` and `-ldflags "-s -w"` (symbols and debug info stripped).
- A `scratch` base would be about the size of the binary alone, but it has no shell, so a supervisor cannot run in it. The extra few MB of alpine is the price for swapping the binary without restarting the container.

### 2.4 Commands used

**One-time setup**

```bash
docker volume create app-runtime
docker volume create app-backups

docker build -t shift-engineer-devops:bootstrap --build-arg VERSION=v0 .

docker run -d --name shift-engineer-devops \
  -p 8080:8080 \
  -v app-runtime:/app \
  shift-engineer-devops:bootstrap
```

- **Mount:** the named volume `app-runtime` is mounted at `/app`. On first use it is populated with `/app/server` from the image. From then on, the binary lives in the volume, not in the container's writable layer.
- **Why not `docker cp`:** `docker cp` writes into the container's writable layer. That layer is destroyed by `docker rm`, and the recreated container falls back to the (old) binary in the image. A volume survives `docker rm`.

**Ship a new version (hotfix)**

```bash
./scripts/build-binary.sh              # builds build/server, version auto-increments (v1, v2, ...)
./scripts/hotfix.sh build/server
```

`hotfix.sh` does the following:

1. Copies the current binary to `backups/server-<timestamp>`.
2. Replaces the active binary atomically: `install` to `server.tmp`, then `mv -f` over `server`.
3. Waits for the supervisor to reload the process (`RELOAD_WAIT`, default 3 seconds).
4. Runs the health check (`/health`). If it fails, the backup is restored automatically and the script exits with code 1.
5. Verifies that container ID, image ID, `StartedAt` and `RestartCount` are unchanged.

**Manual rollback**

```bash
ls backups/
./scripts/rollback.sh backups/server-<timestamp>
```

**Restart:** there is no `docker restart` and no `docker rm`. The "restart" is a process reload inside the running container, done by `entrypoint.sh` when it sees the binary hash change. Container ID, image ID and container start time stay the same.

### 2.5 curl output before and after the binary swap

Before:

```bash
curl http://localhost:8080
docker inspect shift-engineer-devops --format 'id={{.Id}} started={{.State.StartedAt}} restarts={{.RestartCount}}'
```

```
<paste output: Hello, DevOps! version=<before>>
<paste output: id=... started=... restarts=0>
```

Swap (either run the pipeline, or):

```bash
./scripts/build-binary.sh
./scripts/hotfix.sh build/server
```

After:

```bash
curl http://localhost:8080
docker inspect shift-engineer-devops --format 'id={{.Id}} started={{.State.StartedAt}} restarts={{.RestartCount}}'
docker logs --tail 5 shift-engineer-devops
```

```
<paste output: Hello, DevOps! version=<after>>
<paste output: id=... started=... restarts=0>   (must be identical to the "before" line)
<paste log lines: supervisor: binary changed, reloading process / supervisor: started ...>
```

| Check | Before | After | Meaning |
|---|---|---|---|
| `version` | `<before>` | `<after>` | Version increased |
| Container ID | `<id>` | same | Container not recreated (no `docker rm`) |
| Image ID | `<image>` | same | Image not rebuilt or replaced |
| `StartedAt` / `RestartCount` | `<t>` / `0` | same | Container not restarted |
| `docker events` (separate terminal) | no events | no events | No `restart`, `die` or `start` event was emitted |

To reproduce the "no events" check, run this in a second terminal before the swap:

```bash
docker events --filter container=shift-engineer-devops
```

The app also exposes `/health`, which returns `{"status":"ok","version":"<version>"}`.

### 2.6 Chosen approach and why it fits a production hotfix

The binary lives on a volume mounted into the container, and a small supervisor (PID 1) restarts only the application process when the binary changes. This suits a production hotfix because nothing has to be rebuilt, pushed or pulled: the fix is a few-MB file swap that takes 1 to 3 seconds instead of a full image rollout. The container keeps its identity, network, ports and configuration, so the blast radius is limited to one process reload. The swap is atomic (`install` then `mv`), every deploy is preceded by a timestamped backup, and a failed health check restores the previous binary automatically. Because the binary is stored on a volume, it also survives `docker rm`, so recreating the container never reverts to an older version.

---

## 3. Part 2: Jenkins pipeline

### 3.1 Jenkinsfile

```groovy
pipeline {
    agent any

    options {
        skipDefaultCheckout(true)
        disableConcurrentBuilds()
        timestamps()
        timeout(time: 20, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '20'))
    }

    parameters {
        booleanParam(
            name: 'PUSH_IMAGE',
            defaultValue: false,
            description: 'Push image ke registry. Jika false, tahap Push hanya disimulasikan.'
        )
        choice(
            name: 'DEPLOY_MODE',
            choices: ['local', 'ssh'],
            description: 'local: agent satu host dengan container (akses Docker socket). ssh: deploy ke host lain via SSH.'
        )
    }

    environment {
        IMAGE_NAME       = 'shift-engineer-devops'
        REGISTRY         = 'registry.example.com/shift-engineer'
        REGISTRY_CRED_ID = 'registry-credentials'
        SSH_CRED_ID      = 'deploy-ssh-key'

        CONTAINER_NAME   = 'shift-engineer-devops'
        DEPLOY_DIR       = '/opt/shift-engineer-devops'
        DEPLOY_HOST      = 'deploy.example.com'
        DEPLOY_USER      = 'deploy'
        HEALTH_URL       = "${params.DEPLOY_MODE == 'ssh' ? 'http://localhost:8080/health' : 'http://host.docker.internal:8080/health'}"
        APP_URL          = "${params.DEPLOY_MODE == 'ssh' ? 'http://localhost:8080' : 'http://host.docker.internal:8080'}"
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
                sh 'chmod +x scripts/*.sh'
                script {
                    env.GIT_SHORT = sh(returnStdout: true, script: 'git rev-parse --short HEAD').trim()
                    env.VERSION   = "v${env.BUILD_NUMBER}-${env.GIT_SHORT}"
                }
                echo "Commit  : ${env.GIT_SHORT}"
                echo "Version : ${env.VERSION}"
            }
        }

        stage('Test') {
            steps {
                sh 'go version'
                sh 'go vet ./...'
                sh 'go test ./... -count=1 -cover'
            }
        }

        stage('Build Image') {
            steps {
                sh '''
                    docker build \
                        --build-arg VERSION="${VERSION}" \
                        --label org.opencontainers.image.revision="${GIT_SHORT}" \
                        --label org.opencontainers.image.version="${VERSION}" \
                        -t "${IMAGE_NAME}:${VERSION}" \
                        -t "${IMAGE_NAME}:latest" \
                        .
                '''
            }
        }

        stage('Push') {
            when { expression { params.PUSH_IMAGE } }
            steps {
                withCredentials([usernamePassword(
                    credentialsId: env.REGISTRY_CRED_ID,
                    usernameVariable: 'REG_USER',
                    passwordVariable: 'REG_PASS'
                )]) {
                    sh '''
                        echo "${REG_PASS}" | docker login "${REGISTRY%%/*}" -u "${REG_USER}" --password-stdin
                        docker tag "${IMAGE_NAME}:${VERSION}" "${REGISTRY}/${IMAGE_NAME}:${VERSION}"
                        docker tag "${IMAGE_NAME}:${VERSION}" "${REGISTRY}/${IMAGE_NAME}:latest"
                        docker push "${REGISTRY}/${IMAGE_NAME}:${VERSION}"
                        docker push "${REGISTRY}/${IMAGE_NAME}:latest"
                        docker logout "${REGISTRY%%/*}"
                    '''
                }
            }
        }

        stage('Push (simulated)') {
            when { expression { !params.PUSH_IMAGE } }
            steps {
                echo "Simulasi push. Registry     : ${env.REGISTRY}"
                echo "Simulasi push. Image        : ${env.REGISTRY}/${env.IMAGE_NAME}:${env.VERSION}"
                echo "Simulasi push. Credential ID: ${env.REGISTRY_CRED_ID} (Username with password)"
            }
        }

        stage('Extract Binary') {
            steps {
                sh '''
                    mkdir -p build
                    docker rm -f "extract-${BUILD_NUMBER}" >/dev/null 2>&1 || true
                    docker create --name "extract-${BUILD_NUMBER}" "${IMAGE_NAME}:${VERSION}" >/dev/null
                    docker cp "extract-${BUILD_NUMBER}:/app/server" build/server
                    docker rm -f "extract-${BUILD_NUMBER}" >/dev/null
                    chmod +x build/server
                    ls -lh build/server
                '''
                archiveArtifacts artifacts: 'build/server', fingerprint: true
            }
        }

        stage('Deploy') {
            steps {
                script {
                    if (params.DEPLOY_MODE == 'ssh') {
                        sshagent(credentials: [env.SSH_CRED_ID]) {
                            sh '''
                                TARGET="${DEPLOY_USER}@${DEPLOY_HOST}"
                                OPTS="-o StrictHostKeyChecking=accept-new"

                                ssh ${OPTS} "${TARGET}" "mkdir -p ${DEPLOY_DIR}/scripts ${DEPLOY_DIR}/build ${DEPLOY_DIR}/runtime ${DEPLOY_DIR}/backups"
                                scp ${OPTS} scripts/hotfix.sh scripts/rollback.sh "${TARGET}:${DEPLOY_DIR}/scripts/"
                                scp ${OPTS} build/server "${TARGET}:${DEPLOY_DIR}/build/server"

                                ssh ${OPTS} "${TARGET}" \
                                    "cd ${DEPLOY_DIR} && chmod +x scripts/*.sh && CONTAINER_NAME=${CONTAINER_NAME} HEALTH_URL=${HEALTH_URL} ./scripts/hotfix.sh build/server"
                            '''
                        }
                    } else {
                        sh '''
                            CONTAINER_BINARY="${DEPLOY_DIR}/runtime/server" \
                            BACKUP_DIR="${DEPLOY_DIR}/backups" \
                            ./scripts/hotfix.sh build/server
                        '''
                    }
                }
            }
        }

        stage('Verify Version') {
            steps {
                script {
                    if (params.DEPLOY_MODE == 'ssh') {
                        sshagent(credentials: [env.SSH_CRED_ID]) {
                            sh '''
                                RESP="$(ssh -o StrictHostKeyChecking=accept-new "${DEPLOY_USER}@${DEPLOY_HOST}" "curl -fsS ${APP_URL}")"
                                echo "${RESP}"
                                echo "${RESP}" | grep -q "version=${VERSION}"
                            '''
                        }
                    } else {
                        sh '''
                            RESP="$(curl -fsS "${APP_URL}")"
                            echo "${RESP}"
                            echo "${RESP}" | grep -q "version=${VERSION}"
                        '''
                    }
                }
            }
        }
    }

    post {
        always {
            sh 'docker rm -f "extract-${BUILD_NUMBER}" >/dev/null 2>&1 || true'
        }
        success {
            echo "Deploy ${env.VERSION} berhasil. Container dan image tidak di-rebuild atau di-recreate."
        }
        failure {
            echo 'Pipeline gagal. Jika gagal setelah Deploy, hotfix.sh sudah melakukan auto-rollback saat health check gagal. Rollback manual: ./scripts/rollback.sh backups/<file>'
        }
    }
}
```

### 3.2 Stages

| # | Stage | What it does |
|---|---|---|
| 7 | Checkout | `checkout scm`, computes `git rev-parse --short HEAD`, sets `VERSION=v<BUILD_NUMBER>-<commit>` |
| 8 | Test | `go vet ./...` and `go test ./... -count=1 -cover` |
| 9 | Build Image | `docker build --build-arg VERSION=...`, tagged with version and `latest` (version injected with `-ldflags`) |
| 10 | Push / Push (simulated) | With `PUSH_IMAGE=true`: login with a Jenkins credential and push to the registry. Otherwise it only prints the registry, image name and credential ID that would be used |
| - | Extract Binary | `docker create` + `docker cp` takes `/app/server` out of the freshly built image and archives it |
| 11 | Deploy | Runs `scripts/hotfix.sh` (`local` mode: agent with Docker socket access; `ssh` mode: copies the binary and scripts to the target host and runs the hotfix there) |
| - | Verify Version | Calls the app and asserts that the response contains `version=<VERSION>` |

**Registry and credentials (Push stage)**

- Registry: `REGISTRY` in the `environment` block, for example `ghcr.io/<user>` or `docker.io/<user>`.
- Jenkins credential `registry-credentials` (type *Username with password*, use an access token rather than the account password).
- For `ssh` deploy mode: credential `deploy-ssh-key` (type *SSH Username with private key*) and the *SSH Agent* plugin.

The binary that gets deployed is extracted from the image that was just built. So the running binary and the tagged image always contain the same code and the same injected version.

### 3.3 Running Jenkins locally

Jenkins runs as a container that has Go and the Docker CLI, and controls the host's Docker through the socket. The runtime and backup directories are shared with the application container through the named volumes.

```bash
docker build -t jenkins-go-docker ./jenkins

MSYS_NO_PATHCONV=1 docker run -d --name jenkins \
  -p 8081:8080 -p 50000:50000 \
  --add-host=host.docker.internal:host-gateway \
  -v jenkins_home:/var/jenkins_home \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v app-runtime:/opt/shift-engineer-devops/runtime \
  -v app-backups:/opt/shift-engineer-devops/backups \
  jenkins-go-docker
```

(`MSYS_NO_PATHCONV=1` is only needed in Git Bash on Windows.)

1. Open `http://localhost:8081` and unlock Jenkins with the initial admin password.
2. Create a *Pipeline* job: *Pipeline script from SCM*, Git, repository URL, branch `*/master`, script path `Jenkinsfile`.
3. Click **Build Now**.

The Jenkins container runs as root, which is acceptable for a lab or test environment but not for production.

### 3.4 Successful pipeline run

![Pipeline stage view, all stages passed](docs/pipeline-success.png)

Console log: [`docs/pipeline-console.log`](docs/pipeline-console.log)

<!-- Replace with your own screenshot and console output. Stage "Push" is shown as skipped (grey) when PUSH_IMAGE=false; "Push (simulated)" runs instead. -->

Key lines expected in the log:

```
Version : v<N>-<commit>
ok  	.../cmd/internal/server	... coverage: 100.0% of statements
Successfully tagged shift-engineer-devops:v<N>-<commit>
Stage "Push" skipped due to when conditional
Container ID unchanged: <id>
Image ID unchanged: <image>
Container not restarted: StartedAt=<t> RestartCount=0
Hello, DevOps! version=v<N>-<commit>
Finished: SUCCESS
```

### 3.5 Rollback when the Deploy stage fails midway

Rollback is built into `scripts/hotfix.sh`, which the Deploy stage calls. How each failure point is handled:

- **Before the swap** (binary not found, container missing, no active binary): the script exits with code 1 before touching anything. Nothing has changed and the pipeline stops at Deploy.
- **The new binary is broken** (crashes, or `/health` fails after the reload): the script restores the backup taken at the start (`install` + `mv`, so it is atomic), waits for the supervisor to reload the previous binary, prints `Rollback completed` and exits with code 1. Jenkins marks the Deploy stage as failed and does not run Verify Version, while the service keeps serving the previous version.
- **The swap is interrupted halfway:** the binary is never half-written because it is copied to `server.tmp` and moved into place with an atomic `mv`. If the Jenkins agent dies after the move but before the health check, the timestamped backup is still on the `app-backups` volume and `./scripts/rollback.sh backups/<file>` restores it.
- **After a rollback:** if the restored binary is also unhealthy, the supervisor keeps retrying to start it every second, and the script still fails loudly instead of reporting success.

Since every image is tagged with its version (`v<N>-<commit>`), an older release can also be redeployed by extracting the binary from that tag and running `hotfix.sh` with it.

---

## 4. Known limitations

- Only the health check triggers an automatic rollback. If **Verify Version** fails (the process is healthy but reports an unexpected version), the pipeline fails but the binary is not restored automatically. Use `rollback.sh` manually.
- The supervisor polls every second and `hotfix.sh` waits `RELOAD_WAIT` seconds, so there is a brief window (about 1 to 3 seconds) where the service restarts its process. This is not zero-downtime.
- The running binary can differ from the binary inside the image until the next full image deploy. The pipeline mitigates this by building the image and extracting the binary from it, so both carry the same version.
- Jenkins runs as root with the Docker socket mounted. This is for local demonstration only.